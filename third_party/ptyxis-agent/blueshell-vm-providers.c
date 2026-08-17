/* blueshell-vm-providers.c
 *
 * BlueShell addition: VM and cluster spawn targets on top of the Ptyxis
 * agent's container model — Lima, LibVirt, Incus, Kubernetes, and
 * KubeVirt. Each running instance becomes a PtyxisSessionContainer whose
 * command prefix routes the spawned shell into the target:
 *
 *   lima        limactl shell NAME <shell…>
 *   incus       incus exec NAME -- <shell…>
 *   kubernetes  kubectl exec -i -t POD [-c CONTAINER] -- <shell…>
 *   libvirt     sh -c 'exec virsh console "$0"' NAME   (console targets
 *   kubevirt    sh -c 'exec virtctl console -n "$0" "$1"' NS NAME
 *   corral      sh -c 'exec corral ssh "$0"' NAME  (VMs)
 *               sh -c 'exec corral ct console "$0"' NAME  (containers)
 *               take no command; the sh -c trick swallows the appended
 *               shell argv as unused positional parameters)
 *
 * Providers are OFF by default. Opt in with a comma-separated list in
 * the BLUESHELL_VM_PROVIDERS environment variable, e.g.
 *   BLUESHELL_VM_PROVIDERS=lima,incus
 * A provider whose CLI tool is missing from PATH is silently skipped.
 * Enumeration is a one-shot at agent startup (v1); re-enumeration on
 * picker open can layer on later without changing this interface.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "config.h"

#include <string.h>

#include <json-glib/json-glib.h>

#include "blueshell-vm-providers.h"
#include "ptyxis-run-context.h"
#include "ptyxis-session-container.h"

/* Run a host command and capture stdout. Returns NULL on any failure. */
static char *
run_host_capture (const char * const *argv)
{
  g_autoptr(PtyxisRunContext) run_context = NULL;
  g_autoptr(GSubprocess) subprocess = NULL;
  g_autofree char *stdout_buf = NULL;

  g_assert (argv != NULL && argv[0] != NULL);

  run_context = ptyxis_run_context_new ();
  ptyxis_run_context_push_host (run_context);
  ptyxis_run_context_append_args (run_context, argv);

  if (!(subprocess = ptyxis_run_context_spawn_with_flags (run_context,
                                                          (G_SUBPROCESS_FLAGS_STDOUT_PIPE |
                                                           G_SUBPROCESS_FLAGS_STDERR_SILENCE),
                                                          NULL)))
    return NULL;

  if (!g_subprocess_communicate_utf8 (subprocess, NULL, NULL, &stdout_buf, NULL, NULL))
    return NULL;

  if (!g_subprocess_get_successful (subprocess))
    return NULL;

  return g_steal_pointer (&stdout_buf);
}

static PtyxisIpcContainer *
make_container (const char         *id,
                const char         *provider,
                const char         *display_name,
                const char         *icon_name,
                const char * const *command_prefix)
{
  PtyxisSessionContainer *container = ptyxis_session_container_new ();
  PtyxisIpcContainer *ipc = PTYXIS_IPC_CONTAINER (container);

  ptyxis_ipc_container_set_id (ipc, id);
  ptyxis_ipc_container_set_provider (ipc, provider);
  ptyxis_ipc_container_set_display_name (ipc, display_name);
  ptyxis_ipc_container_set_icon_name (ipc, icon_name);
  ptyxis_session_container_set_command_prefix (container, command_prefix);

  return ipc;
}

/* ---- Lima: `limactl list --json` emits one JSON object per line ---- */

void
blueshell_vm_providers_add_lima (GPtrArray *containers)
{
  g_autofree char *out = NULL;
  g_auto(GStrv) lines = NULL;

  if (!(out = run_host_capture ((const char * const []) { "limactl", "list", "--json", NULL })))
    return;

  lines = g_strsplit (out, "\n", -1);

  for (guint i = 0; lines[i] != NULL; i++)
    {
      g_autoptr(JsonParser) parser = json_parser_new ();
      JsonObject *obj;
      const char *name;
      const char *status;

      if (lines[i][0] == '\0')
        continue;
      if (!json_parser_load_from_data (parser, lines[i], -1, NULL))
        continue;
      if (!JSON_NODE_HOLDS_OBJECT (json_parser_get_root (parser)))
        continue;

      obj = json_node_get_object (json_parser_get_root (parser));
      if (!json_object_has_member (obj, "name") || !json_object_has_member (obj, "status"))
        continue;

      name = json_object_get_string_member (obj, "name");
      status = json_object_get_string_member (obj, "status");
      if (g_strcmp0 (status, "Running") != 0)
        continue;

      {
        g_autofree char *id = g_strdup_printf ("lima-%s", name);
        g_ptr_array_add (containers,
                         make_container (id, "lima", name, "container-generic-symbolic",
                                         (const char * const []) { "limactl", "shell", name, NULL }));
      }
    }
}

/* ---- Incus: `incus list --format json` is a JSON array ---- */

void
blueshell_vm_providers_add_incus (GPtrArray *containers)
{
  g_autofree char *out = NULL;
  g_autoptr(JsonParser) parser = json_parser_new ();
  JsonArray *arr;
  guint len;

  if (!(out = run_host_capture ((const char * const []) { "incus", "list", "--format", "json", NULL })))
    return;
  if (!json_parser_load_from_data (parser, out, -1, NULL))
    return;
  if (!JSON_NODE_HOLDS_ARRAY (json_parser_get_root (parser)))
    return;

  arr = json_node_get_array (json_parser_get_root (parser));
  len = json_array_get_length (arr);

  for (guint i = 0; i < len; i++)
    {
      JsonObject *obj = json_array_get_object_element (arr, i);
      const char *name;
      const char *status;

      if (obj == NULL ||
          !json_object_has_member (obj, "name") ||
          !json_object_has_member (obj, "status"))
        continue;

      name = json_object_get_string_member (obj, "name");
      status = json_object_get_string_member (obj, "status");
      if (g_strcmp0 (status, "Running") != 0)
        continue;

      {
        g_autofree char *id = g_strdup_printf ("incus-%s", name);
        /* `incus exec` works for containers and (with an agent) VMs. */
        g_ptr_array_add (containers,
                         make_container (id, "incus", name, "container-generic-symbolic",
                                         (const char * const []) { "incus", "exec", name, "--", NULL }));
      }
    }
}

/* ---- LibVirt: `virsh list --name` → one running domain per line ---- */

void
blueshell_vm_providers_add_libvirt (GPtrArray *containers)
{
  g_autofree char *out = NULL;
  g_auto(GStrv) lines = NULL;

  if (!(out = run_host_capture ((const char * const []) { "virsh", "--readonly", "list", "--name", NULL })))
    return;

  lines = g_strsplit (out, "\n", -1);

  for (guint i = 0; lines[i] != NULL; i++)
    {
      const char *name = g_strstrip (lines[i]);

      if (name[0] == '\0')
        continue;

      {
        g_autofree char *id = g_strdup_printf ("libvirt-%s", name);
        /* virsh console takes no command; swallow the appended shell
         * argv as unused positional parameters of sh -c. */
        g_ptr_array_add (containers,
                         make_container (id, "libvirt", name, "computer-symbolic",
                                         (const char * const []) {
                                           "sh", "-c", "exec virsh console \"$0\"", name, NULL
                                         }));
      }
    }
}

/* ---- Kubernetes: `kubectl get pods -o json` (current context/ns) ---- */

void
blueshell_vm_providers_add_kubernetes (GPtrArray *containers)
{
  g_autofree char *out = NULL;
  g_autoptr(JsonParser) parser = json_parser_new ();
  JsonObject *root;
  JsonArray *items;
  guint len;

  if (!(out = run_host_capture ((const char * const []) { "kubectl", "get", "pods", "-o", "json", NULL })))
    return;
  if (!json_parser_load_from_data (parser, out, -1, NULL))
    return;
  if (!JSON_NODE_HOLDS_OBJECT (json_parser_get_root (parser)))
    return;

  root = json_node_get_object (json_parser_get_root (parser));
  if (!json_object_has_member (root, "items"))
    return;

  items = json_object_get_array_member (root, "items");
  len = json_array_get_length (items);

  for (guint i = 0; i < len; i++)
    {
      JsonObject *pod = json_array_get_object_element (items, i);
      JsonObject *metadata;
      JsonObject *status;
      JsonObject *spec;
      JsonArray *pod_containers = NULL;
      const char *pod_name;
      guint n_containers = 1;

      if (pod == NULL ||
          !json_object_has_member (pod, "metadata") ||
          !json_object_has_member (pod, "status"))
        continue;

      metadata = json_object_get_object_member (pod, "metadata");
      status = json_object_get_object_member (pod, "status");

      if (!json_object_has_member (metadata, "name"))
        continue;
      if (g_strcmp0 (json_object_get_string_member (status, "phase"), "Running") != 0)
        continue;

      pod_name = json_object_get_string_member (metadata, "name");

      if (json_object_has_member (pod, "spec") &&
          (spec = json_object_get_object_member (pod, "spec")) &&
          json_object_has_member (spec, "containers"))
        {
          pod_containers = json_object_get_array_member (spec, "containers");
          n_containers = json_array_get_length (pod_containers);
        }

      /* Single-container pods list as the pod; multi-container pods get
       * one entry per container, "pod/container". */
      for (guint j = 0; j < MAX (n_containers, 1); j++)
        {
          const char *container_name = NULL;

          if (pod_containers != NULL && n_containers > 1)
            {
              JsonObject *c = json_array_get_object_element (pod_containers, j);
              if (c == NULL || !json_object_has_member (c, "name"))
                continue;
              container_name = json_object_get_string_member (c, "name");
            }

          {
            g_autofree char *display = container_name != NULL
              ? g_strdup_printf ("%s/%s", pod_name, container_name)
              : g_strdup (pod_name);
            g_autofree char *id = g_strdup_printf ("k8s-%s", display);
            PtyxisIpcContainer *ipc;

            if (container_name != NULL)
              ipc = make_container (id, "kubernetes", display, "network-server-symbolic",
                                    (const char * const []) {
                                      "kubectl", "exec", "-i", "-t", pod_name,
                                      "-c", container_name, "--", NULL
                                    });
            else
              ipc = make_container (id, "kubernetes", display, "network-server-symbolic",
                                    (const char * const []) {
                                      "kubectl", "exec", "-i", "-t", pod_name, "--", NULL
                                    });

            g_ptr_array_add (containers, ipc);
          }

          if (pod_containers == NULL || n_containers <= 1)
            break;
        }
    }
}

/* ---- KubeVirt: `kubectl get vmi -o json` + virtctl console ---- */

void
blueshell_vm_providers_add_kubevirt (GPtrArray *containers)
{
  g_autofree char *out = NULL;
  g_autoptr(JsonParser) parser = json_parser_new ();
  JsonObject *root;
  JsonArray *items;
  guint len;

  if (!(out = run_host_capture ((const char * const []) { "kubectl", "get", "vmi", "-o", "json", NULL })))
    return;
  if (!json_parser_load_from_data (parser, out, -1, NULL))
    return;
  if (!JSON_NODE_HOLDS_OBJECT (json_parser_get_root (parser)))
    return;

  root = json_node_get_object (json_parser_get_root (parser));
  if (!json_object_has_member (root, "items"))
    return;

  items = json_object_get_array_member (root, "items");
  len = json_array_get_length (items);

  for (guint i = 0; i < len; i++)
    {
      JsonObject *vmi = json_array_get_object_element (items, i);
      JsonObject *metadata;
      JsonObject *status;
      const char *name;
      const char *ns = "default";

      if (vmi == NULL ||
          !json_object_has_member (vmi, "metadata") ||
          !json_object_has_member (vmi, "status"))
        continue;

      metadata = json_object_get_object_member (vmi, "metadata");
      status = json_object_get_object_member (vmi, "status");

      if (!json_object_has_member (metadata, "name"))
        continue;
      if (g_strcmp0 (json_object_get_string_member (status, "phase"), "Running") != 0)
        continue;

      name = json_object_get_string_member (metadata, "name");
      if (json_object_has_member (metadata, "namespace"))
        ns = json_object_get_string_member (metadata, "namespace");

      {
        g_autofree char *id = g_strdup_printf ("kubevirt-%s-%s", ns, name);
        g_autofree char *display = g_strdup_printf ("%s (%s)", name, ns);

        g_ptr_array_add (containers,
                         make_container (id, "kubevirt", display, "computer-symbolic",
                                         (const char * const []) {
                                           "sh", "-c", "exec virtctl console -n \"$0\" \"$1\"",
                                           ns, name, NULL
                                         }));
      }
    }
}

/* ---- Corral (tuna-os VM/CT manager): `corral list` + `corral ct list`.
 * No machine-readable list output yet upstream, so parse the table
 * tolerantly: skip the header row, first column is the name, and the
 * row must contain "running" (any case). VMs attach via `corral ssh`,
 * containers via `corral ct console` — both are console-style, so the
 * sh -c "$0" trick swallows the appended shell argv. ---- */

static void
add_corral_rows (GPtrArray  *containers,
                 const char *output,
                 gboolean    is_ct)
{
  g_auto(GStrv) lines = NULL;

  if (output == NULL)
    return;

  lines = g_strsplit (output, "\n", -1);

  for (guint i = 0; lines[i] != NULL; i++)
    {
      g_auto(GStrv) cols = NULL;
      g_autofree char *lower = NULL;
      const char *name;

      g_strstrip (lines[i]);
      if (lines[i][0] == '\0')
        continue;

      lower = g_ascii_strdown (lines[i], -1);
      if (i == 0 && g_str_has_prefix (lower, "name"))
        continue; /* header row */
      if (strstr (lower, "running") == NULL)
        continue;

      cols = g_strsplit_set (lines[i], " \t", -1);
      name = cols[0];
      if (name == NULL || name[0] == '\0')
        continue;

      {
        g_autofree char *id = g_strdup_printf ("corral-%s%s", is_ct ? "ct-" : "", name);

        if (is_ct)
          g_ptr_array_add (containers,
                           make_container (id, "corral", name, "container-generic-symbolic",
                                           (const char * const []) {
                                             "sh", "-c", "exec corral ct console \"$0\"", name, NULL
                                           }));
        else
          g_ptr_array_add (containers,
                           make_container (id, "corral", name, "computer-symbolic",
                                           (const char * const []) {
                                             "sh", "-c", "exec corral ssh \"$0\"", name, NULL
                                           }));
      }
    }
}

void
blueshell_vm_providers_add_corral (GPtrArray *containers)
{
  g_autofree char *vms = run_host_capture ((const char * const []) { "corral", "list", NULL });
  g_autofree char *cts = run_host_capture ((const char * const []) { "corral", "ct", "list", NULL });

  add_corral_rows (containers, vms, FALSE);
  add_corral_rows (containers, cts, TRUE);
}

/* ---- Entry point ---- */

typedef struct
{
  const char *name;
  const char *required_tool;
  void (*add) (GPtrArray *containers);
} VmProvider;

static const VmProvider vm_providers[] = {
  { "lima", "limactl", blueshell_vm_providers_add_lima },
  { "libvirt", "virsh", blueshell_vm_providers_add_libvirt },
  { "incus", "incus", blueshell_vm_providers_add_incus },
  { "kubernetes", "kubectl", blueshell_vm_providers_add_kubernetes },
  { "kubevirt", "virtctl", blueshell_vm_providers_add_kubevirt },
  { "corral", "corral", blueshell_vm_providers_add_corral },
};

gboolean
blueshell_vm_provider_is_enabled (const char *name,
                                  const char *env_value)
{
  g_auto(GStrv) enabled = NULL;

  if (env_value == NULL || env_value[0] == '\0')
    return FALSE;

  enabled = g_strsplit (env_value, ",", -1);

  for (guint i = 0; enabled[i] != NULL; i++)
    {
      const char *entry = g_strstrip (enabled[i]);

      if (g_strcmp0 (entry, name) == 0 || g_strcmp0 (entry, "all") == 0)
        return TRUE;
    }

  return FALSE;
}

GPtrArray *
blueshell_vm_providers_enumerate (const char *env_value)
{
  GPtrArray *containers = g_ptr_array_new_with_free_func (g_object_unref);

  for (guint i = 0; i < G_N_ELEMENTS (vm_providers); i++)
    {
      const VmProvider *provider = &vm_providers[i];
      g_autofree char *tool = NULL;

      if (!blueshell_vm_provider_is_enabled (provider->name, env_value))
        continue;

      /* Missing tool => provider unavailable, never an error. In the
       * flatpak case the tool lives on the host; PATH lookup here is a
       * cheap pre-filter and run_host_capture still goes through the
       * host anyway, so only skip when we're NOT sandboxed. */
      tool = g_find_program_in_path (provider->required_tool);
      if (tool == NULL && !g_file_test ("/.flatpak-info", G_FILE_TEST_EXISTS))
        continue;

      provider->add (containers);
    }

  return containers;
}
