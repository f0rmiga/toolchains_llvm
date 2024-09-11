# Copyright 2021 The Bazel Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    "@bazel_tools//tools/cpp:unix_cc_toolchain_config.bzl",
    unix_cc_toolchain_config = "cc_toolchain_config",
)
load(
    ":windows_cc_toolchain_config.bzl", 
    windows_cc_toolchain_config = "cc_toolchain_config",
)
load(
    "//toolchain/internal:common.bzl",
    _check_os_arch_keys = "check_os_arch_keys",
    _os_arch_pair = "os_arch_pair",
)

# Bazel 4.* doesn't support nested starlark functions, so we cannot simplify
# _fmt_flags() by defining it as a nested function.
def _fmt_flags(flags, toolchain_path_prefix):
    return [f.format(toolchain_path_prefix = toolchain_path_prefix) for f in flags]

# Macro for calling cc_toolchain_config from @bazel_tools with setting the
# right paths and flags for the tools.
def cc_toolchain_config(
        name,
        exec_arch,
        exec_os,
        target_arch,
        target_os,
        target_system_name,
        toolchain_path_prefix,
        tools_path_prefix,
        wrapper_bin_prefix,
        compiler_configuration,
        cxx_builtin_include_directories,
        major_llvm_version):
    exec_os_arch_key = _os_arch_pair(exec_os, exec_arch)
    target_os_arch_key = _os_arch_pair(target_os, target_arch)
    _check_os_arch_keys([exec_os_arch_key, target_os_arch_key])

    # A bunch of variables that get passed straight through to
    # `create_cc_toolchain_config_info`.
    # TODO: What do these values mean, and are they actually all correct?
    (
        toolchain_identifier,
        target_cpu,
        target_libc,
        compiler,
        abi_version,
        abi_libc_version,
    ) = {
        "darwin-x86_64": (
            "clang-x86_64-darwin",
            "darwin",
            "macosx",
            "clang",
            "darwin_x86_64",
            "darwin_x86_64",
        ),
        "darwin-aarch64": (
            "clang-aarch64-darwin",
            "darwin",
            "macosx",
            "clang",
            "darwin_aarch64",
            "darwin_aarch64",
        ),
        "linux-aarch64": (
            "clang-aarch64-linux",
            "aarch64",
            "glibc_unknown",
            "clang",
            "clang",
            "glibc_unknown",
        ),
        "linux-x86_64": (
            "clang-x86_64-linux",
            "k8",
            "glibc_unknown",
            "clang",
            "clang",
            "glibc_unknown",
        ),
        "windows-msvc-x86_64": (
            "clang-x86_64-windows-msvc",
            "x64_windows",
            "msvc",
            "clang-cl",
            "clang-cl",
            "msvc",
        ),
    }[target_os_arch_key]

    # Unfiltered compiler flags; these are placed at the end of the command
    # line, so take precendence over any user supplied flags through --copts or
    # such.
    unfiltered_compile_flags = [
        # Do not resolve our symlinked resource prefixes to real paths.
        "-no-canonical-prefixes",
        # Reproducibility
        "-Wno-builtin-macro-redefined",
        "-D__DATE__=\"redacted\"",
        "-D__TIMESTAMP__=\"redacted\"",
        "-D__TIME__=\"redacted\"",
        "-fdebug-prefix-map={}=__bazel_toolchain_llvm_repo__/".format(toolchain_path_prefix),
    ]

    # Default compiler flags:
    compile_flags = [
        "--target=" + target_system_name,
        # Security
        "-U_FORTIFY_SOURCE",  # https://github.com/google/sanitizers/issues/247
    ]

    if target_os != "windows-msvc":
        compile_flags.extend([
            "-fstack-protector",
            "-fno-omit-frame-pointer",
        ])

    dbg_compile_flags = ["-g", "-fstandalone-debug"]

    opt_compile_flags = [
        "-g0",
        "-O2",
        "-D_FORTIFY_SOURCE=1",
        "-DNDEBUG",
        "-ffunction-sections",
        "-fdata-sections",
    ]

    link_flags = [
        "--target=" + target_system_name,
        "-no-canonical-prefixes",
    ]

    # Similar to link_flags, but placed later in the command line such that
    # unused symbols are not stripped.
    link_libs = []

    # Flags related to C++ standard.
    # The linker has no way of knowing if there are C++ objects; so we
    # always link C++ libraries.
    cxx_standard = compiler_configuration["cxx_standard"]
    stdlib = compiler_configuration["stdlib"]
    # Let's be compatible with the old way of specifying the standard library.
    if stdlib == "stdc++":
        print("WARNING: stdc++ is deprecated. Please use libstdc++ instead.")
        stdlib = "libstdc++"
    sysroot_path = compiler_configuration["sysroot_path"]

    cxx_flags = []

    if target_os != "windows-msvc":
        cxx_flags.extend([
            "-std=" + cxx_standard,
            "-stdlib=" + stdlib,
        ])

    if stdlib == "libc++":
        if major_llvm_version >= 14:
            # With C++20, Clang defaults to using C++ rather than Clang modules,
            # which breaks Bazel's `use_module_maps` feature, which is used by
            # `layering_check`. Since Bazel doesn't support C++ modules yet, it
            # is safe to disable them globally until the toolchain shipped by
            # Bazel sets this flag on `use_module_maps`.
            # https://github.com/llvm/llvm-project/commit/0556138624edf48621dd49a463dbe12e7101f17d
            cxx_flags.append("-Xclang")
            cxx_flags.append("-fno-cxx-modules")

        link_flags.extend([
            "-l:libc++.a",
            "-l:libc++abi.a",
            "-l:libunwind.a",
        ])
    elif stdlib == "libstdc++":
        link_flags.extend([
            "-l:libstdc++.a",
        ])
    elif stdlib == "none":
        cxx_flags = [
            "-nostdlib",
        ]

        link_flags.extend([
            "-nostdlib",
        ])
    elif target_os != "windows-msvc":
        # When targetting Windows, we don't need to link against the standard
        # library, as it is provided by the MSVC runtime.
        fail("Unknown value passed for stdlib: {stdlib}".format(stdlib = stdlib))

    archive_flags = []

    if target_os == "darwin":
        ld = "ld64.lld"
        ld_path = toolchain_path_prefix + "/bin/" + ld
        link_flags.extend([
            "-headerpad_max_install_names",
            "-fobjc-link-runtime",

            "-fuse-ld=lld",
            "--ld-path=" + ld_path,

            # Compiler runtime features.
            "-rtlib=compiler-rt",

            "-lm",
            "-ldl",
            "-pthread",
        ])

        # Use the bundled libtool (llvm-libtool-darwin).
        use_libtool = True

        # Pre-installed libtool on macOS has -static as default, but llvm-libtool-darwin needs it
        # explicitly. cc_common.create_link_variables does not automatically add this either if
        # output_file arg to it is None.
        archive_flags.extend([
            "-static",
        ])
    elif target_os == "linux":
        ld = "ld.lld"
        ld_path = toolchain_path_prefix + "/bin/" + ld
        link_flags.extend([
            "-fuse-ld=lld",
            "--ld-path=" + ld_path,
            "-Wl,--build-id=md5",
            "-Wl,--hash-style=gnu",
            "-Wl,-z,relro,-z,now",
            "-lm",
            "-ldl",
            "-pthread",
        ])

        use_libtool = False
    elif target_os == "windows-msvc":
        cxx_flags.extend([
            "/std:" + cxx_standard,
            "-fms-compatibility",
            "-fms-extensions",
        ])
        compile_flags.extend([
            "/MT",
            "/Brepro",
            "/DWIN32",
            "/D_WIN32",
            "/D_WINDOWS",
            "/clang:-isystem{}splat/VC/Tools/MSVC/14.41.17.11/include".format(sysroot_path),
            "/clang:-isystem{}splat/Windows_Kits/10/include/10.0.26100/um".format(sysroot_path),
            "/clang:-isystem{}splat/Windows_Kits/10/include/10.0.26100/shared".format(sysroot_path),
            "/clang:-isystem{}splat/Windows_Kits/10/include/10.0.26100/ucrt".format(sysroot_path),
            # Do not resolve our symlinked resource prefixes to real paths.
            "-no-canonical-prefixes",
            # Reproducibility
            "-Wno-builtin-macro-redefined",
            "/D__DATE__=0",
            "/D__TIMESTAMP__=0",
            "/D__TIME__=0",
            "/clang:-fdebug-prefix-map={}=__bazel_toolchain_llvm_repo__/".format(toolchain_path_prefix),
        ])

        ld = "lld-link"

        link_flags = [
            "/libpath:{}splat/Windows_Kits/10/lib/10.0.26100/ucrt/x64".format(sysroot_path),
            "/libpath:{}splat/Windows_Kits/10/lib/10.0.26100/um/x64".format(sysroot_path),
            "/libpath:{}splat/VC/Tools/MSVC/14.41.17.11/lib/x64".format(sysroot_path),
        ]

        use_libtool = False
    else:
        fail("Unknown value passed for target_os: {}".format(target_os))

    opt_link_flags = ["-Wl,--gc-sections"] if target_os == "linux" else []

    # Coverage flags:
    coverage_compile_flags = ["-fprofile-instr-generate", "-fcoverage-mapping"]
    coverage_link_flags = ["-fprofile-instr-generate"]

    ## NOTE: framework paths is missing here; unix_cc_toolchain_config
    ## doesn't seem to have a feature for this.

    ## NOTE: make variables are missing here; unix_cc_toolchain_config doesn't
    ## pass these to `create_cc_toolchain_config_info`.

    # The requirements here come from
    # https://cs.opensource.google/bazel/bazel/+/master:src/main/starlark/builtins_bzl/common/cc/cc_toolchain_provider_helper.bzl;l=75;drc=f0150efd1cca473640269caaf92b5a23c288089d
    # https://cs.opensource.google/bazel/bazel/+/master:src/main/java/com/google/devtools/build/lib/rules/cpp/CcModule.java;l=1257;drc=6743d76f9ecde726d592e88d8914b9db007b1c43
    # https://cs.opensource.google/bazel/bazel/+/refs/tags/7.0.0:tools/cpp/unix_cc_toolchain_config.bzl;l=192,201;drc=044a14cca2747aeff258fc71eaeb153c08cb34d5
    # NOTE: Ensure these are listed in toolchain_tools in toolchain/internal/common.bzl.
    tool_paths = {
        "ar": tools_path_prefix + ("llvm-ar" if not use_libtool else "libtool"),
        "cpp": tools_path_prefix + "clang-cpp",
        "dwp": tools_path_prefix + "llvm-dwp",
        "gcc": wrapper_bin_prefix + ("cc_wrapper_msvc.sh" if target_os == "windows-msvc" else "cc_wrapper.sh"),
        "gcov": tools_path_prefix + "llvm-profdata",
        "ld": tools_path_prefix + ld,
        "llvm-cov": tools_path_prefix + "llvm-cov",
        "llvm-profdata": tools_path_prefix + "llvm-profdata",
        "nm": tools_path_prefix + "llvm-nm",
        "objcopy": tools_path_prefix + "llvm-objcopy",
        "objdump": tools_path_prefix + "llvm-objdump",
        "strip": tools_path_prefix + "llvm-strip",
    }

    # Replace flags with any user-provided overrides.
    if compiler_configuration["compile_flags"] != None:
        compile_flags = _fmt_flags(compiler_configuration["compile_flags"], toolchain_path_prefix)
    if compiler_configuration["cxx_flags"] != None:
        cxx_flags = _fmt_flags(compiler_configuration["cxx_flags"], toolchain_path_prefix)
    if compiler_configuration["link_flags"] != None:
        link_flags = _fmt_flags(compiler_configuration["link_flags"], toolchain_path_prefix)
    if compiler_configuration["archive_flags"] != None:
        archive_flags = _fmt_flags(compiler_configuration["archive_flags"], toolchain_path_prefix)
    if compiler_configuration["link_libs"] != None:
        link_libs = _fmt_flags(compiler_configuration["link_libs"], toolchain_path_prefix)
    if compiler_configuration["opt_compile_flags"] != None:
        opt_compile_flags = _fmt_flags(compiler_configuration["opt_compile_flags"], toolchain_path_prefix)
    if compiler_configuration["opt_link_flags"] != None:
        opt_link_flags = _fmt_flags(compiler_configuration["opt_link_flags"], toolchain_path_prefix)
    if compiler_configuration["dbg_compile_flags"] != None:
        dbg_compile_flags = _fmt_flags(compiler_configuration["dbg_compile_flags"], toolchain_path_prefix)
    if compiler_configuration["coverage_compile_flags"] != None:
        coverage_compile_flags = _fmt_flags(compiler_configuration["coverage_compile_flags"], toolchain_path_prefix)
    if compiler_configuration["coverage_link_flags"] != None:
        coverage_link_flags = _fmt_flags(compiler_configuration["coverage_link_flags"], toolchain_path_prefix)
    if compiler_configuration["unfiltered_compile_flags"] != None:
        unfiltered_compile_flags = _fmt_flags(compiler_configuration["unfiltered_compile_flags"], toolchain_path_prefix)

    if target_os == "windows-msvc":
        windows_cc_toolchain_config(
            name = name,
            cpu = target_cpu,
            compiler = compiler,
            toolchain_identifier = toolchain_identifier,
            host_system_name = exec_arch,
            target_system_name = target_system_name,
            target_libc = target_libc,
            abi_version = abi_version,
            abi_libc_version = abi_libc_version,
            cxx_builtin_include_directories = cxx_builtin_include_directories,
            tool_paths = tool_paths,
            archiver_flags = archive_flags,
            default_compile_flags = compile_flags,
            cxx_flags = cxx_flags,
            default_link_flags = link_flags,
            supports_parse_showincludes = False,
            builtin_sysroot = sysroot_path,
            msvc_cl_path = tools_path_prefix + "clang-cl",
            msvc_ml_path = tools_path_prefix + "clang-cl",
            msvc_link_path = tools_path_prefix + ld,
            msvc_lib_path = tools_path_prefix + "llvm-lib",
        )
    else:
        # Source: https://cs.opensource.google/bazel/bazel/+/master:tools/cpp/unix_cc_toolchain_config.bzl
        unix_cc_toolchain_config(
            name = name,
            cpu = target_cpu,
            compiler = compiler,
            toolchain_identifier = toolchain_identifier,
            host_system_name = exec_arch,
            target_system_name = target_system_name,
            target_libc = target_libc,
            abi_version = abi_version,
            abi_libc_version = abi_libc_version,
            cxx_builtin_include_directories = cxx_builtin_include_directories,
            tool_paths = tool_paths,
            compile_flags = compile_flags,
            dbg_compile_flags = dbg_compile_flags,
            opt_compile_flags = opt_compile_flags,
            cxx_flags = cxx_flags,
            link_flags = link_flags,
            archive_flags = archive_flags,
            link_libs = link_libs,
            opt_link_flags = opt_link_flags,
            unfiltered_compile_flags = unfiltered_compile_flags,
            coverage_compile_flags = coverage_compile_flags,
            coverage_link_flags = coverage_link_flags,
            supports_start_end_lib = True, # We only support lld, so this is always true.
            builtin_sysroot = sysroot_path,
        )
