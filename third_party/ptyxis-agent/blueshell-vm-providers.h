/* blueshell-vm-providers.h
 *
 * Blueshell addition: VM/cluster spawn targets (Lima, LibVirt, Incus,
 * Kubernetes, KubeVirt, Corral, NSL). See blueshell-vm-providers.c for design notes.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#include <gio/gio.h>

#include "ptyxis-agent-ipc.h"

G_BEGIN_DECLS

/* Enumerate all enabled providers' running instances into a newly
 * allocated GPtrArray of PtyxisIpcContainer (caller owns). env_value is
 * the BLUESHELL_VM_PROVIDERS comma list ("lima,incus", "all", NULL). */
GPtrArray *blueshell_vm_providers_enumerate (const char *env_value);

gboolean blueshell_vm_provider_is_enabled (const char *name,
                                           const char *env_value);

/* Per-backend enumerators, exposed for tests: each appends
 * PtyxisIpcContainer objects for running instances to the array. */
void blueshell_vm_providers_add_lima       (GPtrArray *containers);
void blueshell_vm_providers_add_libvirt    (GPtrArray *containers);
void blueshell_vm_providers_add_incus      (GPtrArray *containers);
void blueshell_vm_providers_add_kubernetes (GPtrArray *containers);
void blueshell_vm_providers_add_kubevirt   (GPtrArray *containers);
void blueshell_vm_providers_add_corral     (GPtrArray *containers);
void blueshell_vm_providers_add_nsl        (GPtrArray *containers);

G_END_DECLS
