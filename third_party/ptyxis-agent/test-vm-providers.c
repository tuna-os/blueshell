/* test-vm-providers.c
 *
 * Unit tests for blueshell-vm-providers.c. Creates fake limactl/incus/
 * virsh/kubectl/virtctl shims in a temp dir, prepends it to PATH, and
 * asserts that enumeration yields the expected containers with the
 * expected spawn prefixes. Runs anywhere — no real VMs needed.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "config.h"

#include <glib/gstdio.h>

#include "blueshell-vm-providers.h"
#include "ptyxis-process-impl.h"

static char *shim_dir;

/* Stubs: normally provided by ptyxis-agent.c / ptyxis-process-impl.c,
 * which pull in the whole agent (D-Bus main loop). The tests only
 * enumerate — they never spawn into a container. */
gint64
ptyxis_agent_get_default_rlimit_nofile (void)
{
  return 1024;
}

PtyxisIpcProcess *
ptyxis_process_impl_new (GDBusConnection  *connection,
                         GSubprocess      *subprocess,
                         const char       *object_path,
                         GError          **error)
{
  (void)connection; (void)subprocess; (void)object_path; (void)error;
  g_assert_not_reached ();
  return NULL;
}

static void
write_shim (const char *name,
            const char *script)
{
  g_autofree char *path = g_build_filename (shim_dir, name, NULL);
  g_autoptr(GError) error = NULL;

  g_file_set_contents (path, script, -1, &error);
  g_assert_no_error (error);
  g_assert_cmpint (g_chmod (path, 0755), ==, 0);
}

static PtyxisIpcContainer *
find_container (GPtrArray  *containers,
                const char *id)
{
  for (guint i = 0; i < containers->len; i++)
    {
      PtyxisIpcContainer *c = g_ptr_array_index (containers, i);
      if (g_strcmp0 (ptyxis_ipc_container_get_id (c), id) == 0)
        return c;
    }
  return NULL;
}

static void
test_enabled_parsing (void)
{
  g_assert_false (blueshell_vm_provider_is_enabled ("lima", NULL));
  g_assert_false (blueshell_vm_provider_is_enabled ("lima", ""));
  g_assert_false (blueshell_vm_provider_is_enabled ("lima", "incus"));
  g_assert_true (blueshell_vm_provider_is_enabled ("lima", "lima"));
  g_assert_true (blueshell_vm_provider_is_enabled ("lima", "incus, lima"));
  g_assert_true (blueshell_vm_provider_is_enabled ("kubevirt", "all"));
}

static void
test_lima (void)
{
  g_autoptr(GPtrArray) containers = g_ptr_array_new_with_free_func (g_object_unref);
  PtyxisIpcContainer *c;

  write_shim ("limactl",
              "#!/bin/sh\n"
              "printf '%s\\n' '{\"name\":\"default\",\"status\":\"Running\"}'\n"
              "printf '%s\\n' '{\"name\":\"stopped-vm\",\"status\":\"Stopped\"}'\n");

  blueshell_vm_providers_add_lima (containers);

  g_assert_cmpuint (containers->len, ==, 1);
  c = find_container (containers, "lima-default");
  g_assert_nonnull (c);
  g_assert_cmpstr (ptyxis_ipc_container_get_provider (c), ==, "lima");
  g_assert_cmpstr (ptyxis_ipc_container_get_display_name (c), ==, "default");
}

static void
test_incus (void)
{
  g_autoptr(GPtrArray) containers = g_ptr_array_new_with_free_func (g_object_unref);

  write_shim ("incus",
              "#!/bin/sh\n"
              "printf '%s' '[{\"name\":\"web\",\"status\":\"Running\"},"
              "{\"name\":\"db\",\"status\":\"Stopped\"},"
              "{\"name\":\"vm1\",\"status\":\"Running\",\"type\":\"virtual-machine\"}]'\n");

  blueshell_vm_providers_add_incus (containers);

  g_assert_cmpuint (containers->len, ==, 2);
  g_assert_nonnull (find_container (containers, "incus-web"));
  g_assert_nonnull (find_container (containers, "incus-vm1"));
  g_assert_null (find_container (containers, "incus-db"));
}

static void
test_libvirt (void)
{
  g_autoptr(GPtrArray) containers = g_ptr_array_new_with_free_func (g_object_unref);
  PtyxisIpcContainer *c;

  write_shim ("virsh",
              "#!/bin/sh\n"
              "printf 'fedora-vm\\n\\n'\n");

  blueshell_vm_providers_add_libvirt (containers);

  g_assert_cmpuint (containers->len, ==, 1);
  c = find_container (containers, "libvirt-fedora-vm");
  g_assert_nonnull (c);
  g_assert_cmpstr (ptyxis_ipc_container_get_icon_name (c), ==, "computer-symbolic");
}

static void
test_kubernetes (void)
{
  g_autoptr(GPtrArray) containers = g_ptr_array_new_with_free_func (g_object_unref);

  write_shim ("kubectl",
              "#!/bin/sh\n"
              "case \"$*\" in\n"
              "*pods*) printf '%s' '{\"items\":["
              "{\"metadata\":{\"name\":\"web-1\"},\"status\":{\"phase\":\"Running\"},"
              "\"spec\":{\"containers\":[{\"name\":\"app\"}]}},"
              "{\"metadata\":{\"name\":\"multi\"},\"status\":{\"phase\":\"Running\"},"
              "\"spec\":{\"containers\":[{\"name\":\"app\"},{\"name\":\"sidecar\"}]}},"
              "{\"metadata\":{\"name\":\"dead\"},\"status\":{\"phase\":\"Failed\"}}"
              "]}' ;;\n"
              "esac\n");

  blueshell_vm_providers_add_kubernetes (containers);

  /* web-1 (single container) + multi/app + multi/sidecar */
  g_assert_cmpuint (containers->len, ==, 3);
  g_assert_nonnull (find_container (containers, "k8s-web-1"));
  g_assert_nonnull (find_container (containers, "k8s-multi/app"));
  g_assert_nonnull (find_container (containers, "k8s-multi/sidecar"));
}

static void
test_kubevirt (void)
{
  g_autoptr(GPtrArray) containers = g_ptr_array_new_with_free_func (g_object_unref);
  PtyxisIpcContainer *c;

  write_shim ("kubectl",
              "#!/bin/sh\n"
              "case \"$*\" in\n"
              "*vmi*) printf '%s' '{\"items\":["
              "{\"metadata\":{\"name\":\"win11\",\"namespace\":\"vms\"},"
              "\"status\":{\"phase\":\"Running\"}}"
              "]}' ;;\n"
              "esac\n");

  blueshell_vm_providers_add_kubevirt (containers);

  g_assert_cmpuint (containers->len, ==, 1);
  c = find_container (containers, "kubevirt-vms-win11");
  g_assert_nonnull (c);
  g_assert_cmpstr (ptyxis_ipc_container_get_display_name (c), ==, "win11 (vms)");
}

static void
test_corral (void)
{
  g_autoptr(GPtrArray) containers = g_ptr_array_new_with_free_func (g_object_unref);
  PtyxisIpcContainer *c;

  write_shim ("corral",
              "#!/bin/sh\n"
              "case \"$1 $2\" in\n"
              "'ct list') printf 'NAME    STATE\\ndevbox  Running\\nold-ct  Stopped\\n' ;;\n"
              "'list ')   printf 'NAME    BACKEND  STATE\\nweb-vm  local    Running\\ndown    kubevirt Stopped\\n' ;;\n"
              "esac\n");

  blueshell_vm_providers_add_corral (containers);

  g_assert_cmpuint (containers->len, ==, 2);
  c = find_container (containers, "corral-web-vm");
  g_assert_nonnull (c);
  g_assert_cmpstr (ptyxis_ipc_container_get_icon_name (c), ==, "computer-symbolic");
  c = find_container (containers, "corral-ct-devbox");
  g_assert_nonnull (c);
  g_assert_cmpstr (ptyxis_ipc_container_get_icon_name (c), ==, "container-generic-symbolic");
  g_assert_null (find_container (containers, "corral-down"));
  g_assert_null (find_container (containers, "corral-ct-old-ct"));
}

static void
test_enumerate_respects_env (void)
{
  /* Only lima enabled: incus shim exists but must not be consulted. */
  g_autoptr(GPtrArray) containers = blueshell_vm_providers_enumerate ("lima");

  g_assert_nonnull (find_container (containers, "lima-default"));
  g_assert_null (find_container (containers, "incus-web"));

  /* Nothing enabled → nothing listed. */
  {
    g_autoptr(GPtrArray) none = blueshell_vm_providers_enumerate (NULL);
    g_assert_cmpuint (none->len, ==, 0);
  }
}

int
main (int    argc,
      char **argv)
{
  g_autofree char *old_path = g_strdup (g_getenv ("PATH"));
  g_autofree char *new_path = NULL;
  g_autoptr(GError) error = NULL;

  g_test_init (&argc, &argv, NULL);

  shim_dir = g_dir_make_tmp ("blueshell-vm-XXXXXX", &error);
  g_assert_no_error (error);

  new_path = g_strdup_printf ("%s:%s", shim_dir, old_path);
  g_setenv ("PATH", new_path, TRUE);

  g_test_add_func ("/vm-providers/enabled-parsing", test_enabled_parsing);
  g_test_add_func ("/vm-providers/lima", test_lima);
  g_test_add_func ("/vm-providers/incus", test_incus);
  g_test_add_func ("/vm-providers/libvirt", test_libvirt);
  g_test_add_func ("/vm-providers/kubernetes", test_kubernetes);
  g_test_add_func ("/vm-providers/kubevirt", test_kubevirt);
  g_test_add_func ("/vm-providers/corral", test_corral);
  g_test_add_func ("/vm-providers/enumerate-env", test_enumerate_respects_env);

  return g_test_run ();
}
