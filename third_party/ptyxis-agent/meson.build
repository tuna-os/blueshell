project('ptyxis-agent', 'c',
  version: '49.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 0.62.0',
  default_options: [
    'c_std=gnu11',
    'warning_level=2',
    'libexecdir=/app/libexec',
  ],
)

gnome = import('gnome')
cc = meson.get_compiler('c')

release_link_args = []
config_h = configuration_data()

PTYXIS_AGENT_MIN_GLIB_MAJOR = 2
PTYXIS_AGENT_MIN_GLIB_MINOR = 56
PTYXIS_AGENT_MIN_GLIB_VERSION = '@0@.@1@'.format(PTYXIS_AGENT_MIN_GLIB_MAJOR, PTYXIS_AGENT_MIN_GLIB_MINOR)

ptyxis_agent_deps = [
  dependency('gio-2.0', version: '>= @0@'.format(PTYXIS_AGENT_MIN_GLIB_VERSION)),
  dependency('gio-unix-2.0', version: '>= @0@'.format(PTYXIS_AGENT_MIN_GLIB_VERSION)),
  dependency('json-glib-1.0'),
]

ptyxis_agent_ipc = gnome.gdbus_codegen('ptyxis-agent-ipc',
           sources: 'org.gnome.Ptyxis.Agent.xml',
  interface_prefix: 'org.gnome.Ptyxis.',
         namespace: 'PtyxisIpc',
)

ptyxis_agent_sources = [
  ptyxis_agent_ipc,
  files([
    'blueshell-vm-providers.c',
    'ptyxis-agent-util.c',
    'ptyxis-container-provider.c',
    'ptyxis-distrobox-container.c',
    'ptyxis-podman-container.c',
    'ptyxis-podman-provider.c',
    'ptyxis-process-impl.c',
    'ptyxis-run-context.c',
    'ptyxis-session-container.c',
    'ptyxis-toolbox-container.c',
    'ptyxis-unix-fd-map.c',
    'ptyxis-agent.c',
    'ptyxis-agent-impl.c',
  ]),
]

ptyxis_agent_c_args = [
  '-DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_@0@_@1@'.format(PTYXIS_AGENT_MIN_GLIB_MAJOR, PTYXIS_AGENT_MIN_GLIB_MINOR),
  '-DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_@0@_@1@'.format(PTYXIS_AGENT_MIN_GLIB_MAJOR, PTYXIS_AGENT_MIN_GLIB_MINOR),
]

executable('ptyxis-agent', ptyxis_agent_sources,
         dependencies: ptyxis_agent_deps,
              install: true,
          install_dir: get_option('libexecdir'),
               c_args: ptyxis_agent_c_args,
)

# BlueShell: unit test for the VM providers' enumeration/parsing. Uses
# fake CLI shims on PATH (see test-vm-providers.c), so it runs anywhere.
test_vm_providers = executable('test-vm-providers',
  [ptyxis_agent_ipc, files([
    'blueshell-vm-providers.c',
    'ptyxis-agent-util.c',
    'ptyxis-container-provider.c',
    'ptyxis-run-context.c',
    'ptyxis-session-container.c',
    'ptyxis-unix-fd-map.c',
    'test-vm-providers.c',
  ])],
  dependencies: ptyxis_agent_deps,
  c_args: ptyxis_agent_c_args,
)
test('vm-providers', test_vm_providers)
