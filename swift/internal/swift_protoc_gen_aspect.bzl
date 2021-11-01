# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""An aspect attached to `proto_library` targets to generate Swift artifacts."""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":attrs.bzl", "swift_config_attrs")
load(":compiling.bzl", "new_objc_provider")
load(
    ":feature_names.bzl",
    "SWIFT_FEATURE_EMIT_SWIFTINTERFACE",
    "SWIFT_FEATURE_ENABLE_LIBRARY_EVOLUTION",
    "SWIFT_FEATURE_ENABLE_TESTING",
    "SWIFT_FEATURE_GENERATE_FROM_RAW_PROTO_FILES",
)
load(
    ":proto_gen_utils.bzl",
    "declare_generated_files",
    "extract_generated_dir_path",
    "proto_import_path",
    "register_module_mapping_write_action",
)
load(":providers.bzl", "SwiftInfo", "SwiftProtoInfo", "SwiftToolchainInfo")
load(":swift_common.bzl", "swift_common")
load(":utils.bzl", "get_providers")

# The paths of proto files bundled with the runtime. This is mainly the well
# known type protos, but also includes descriptor.proto to make generation of
# files that include options easier. These files should not be generated by
# the aspect because they are already included in the SwiftProtobuf runtime.
# The plugin provides the mapping from these protos to the SwiftProtobuf
# module for us.
# TODO(b/63389580): Once we migrate to proto_lang_toolchain, this information
# can go in the blacklisted_protos list instead.
_RUNTIME_BUNDLED_PROTO_FILES = [
    "google/protobuf/any.proto",
    "google/protobuf/api.proto",
    "google/protobuf/descriptor.proto",
    "google/protobuf/duration.proto",
    "google/protobuf/empty.proto",
    "google/protobuf/field_mask.proto",
    "google/protobuf/source_context.proto",
    "google/protobuf/struct.proto",
    "google/protobuf/timestamp.proto",
    "google/protobuf/type.proto",
    "google/protobuf/wrappers.proto",
]

SwiftProtoCcInfo = provider(
    doc = """\
Wraps a `CcInfo` provider added to a `proto_library` by the Swift proto aspect.

This is necessary because `proto_library` targets already propagate a `CcInfo`
provider for C++ protos, so the Swift proto aspect cannot directly attach its
own. (It's also not good practice to attach providers that you don't own to
arbitrary targets, because you don't know how those targets might change in the
future.) The `swift_proto_library` rule will pick up this provider and return
the underlying `CcInfo` provider as its own.

This provider is an implementation detail not meant to be used by clients.
""",
    fields = {
        "cc_info": "The underlying `CcInfo` provider.",
        "objc_info": "The underlying `apple_common.Objc` provider.",
    },
)

def _filter_out_well_known_types(srcs, proto_source_root):
    """Returns the given list of files, excluding any well-known type protos.

    Args:
        srcs: A list of `.proto` files.
        proto_source_root: the source root where the `.proto` files are.

    Returns:
        The given list of files with any well-known type protos (those living
        under the `google.protobuf` package) removed.
    """
    return [
        f
        for f in srcs
        if proto_import_path(f, proto_source_root) not in
           _RUNTIME_BUNDLED_PROTO_FILES
    ]

def _register_pbswift_generate_action(
        label,
        actions,
        direct_srcs,
        proto_source_root,
        transitive_descriptor_sets,
        module_mapping_file,
        generate_from_proto_sources,
        mkdir_and_run,
        protoc_executable,
        protoc_plugin_executable):
    """Registers actions that generate `.pb.swift` files from `.proto` files.

    Args:
        label: The label of the target being analyzed.
        actions: The context's actions object.
        direct_srcs: The direct `.proto` sources belonging to the target being
            analyzed, which will be passed to `protoc-gen-swift`.
        proto_source_root: the source root where the `.proto` files are.
        transitive_descriptor_sets: The transitive `DescriptorSet`s from the
            `proto_library` being analyzed.
        module_mapping_file: The `File` containing the mapping between `.proto`
            files and Swift modules for the transitive dependencies of the
            target being analyzed. May be `None`, in which case no module
            mapping will be passed (the case for leaf nodes in the dependency
            graph).
        generate_from_proto_sources: True/False for is generation should happen
            from proto source file vs just via the DescriptorSets. The Sets
            don't have source info, so the generated sources won't have
            comments (https://github.com/bazelbuild/bazel/issues/9337).
        mkdir_and_run: The `File` representing the `mkdir_and_run` executable.
        protoc_executable: The `File` representing the `protoc` executable.
        protoc_plugin_executable: The `File` representing the `protoc` plugin
            executable.

    Returns:
        A list of generated `.pb.swift` files corresponding to the `.proto`
        sources.
    """
    generated_files = declare_generated_files(
        label.name,
        actions,
        "pb",
        proto_source_root,
        direct_srcs,
    )
    generated_dir_path = extract_generated_dir_path(
        label.name,
        "pb",
        proto_source_root,
        generated_files,
    )

    mkdir_args = actions.args()
    mkdir_args.add(generated_dir_path)

    protoc_executable_args = actions.args()
    protoc_executable_args.add(protoc_executable)

    protoc_args = actions.args()

    # protoc takes an arg of @NAME as something to read, and expects one arg per
    # line in that file.
    protoc_args.set_param_file_format("multiline")
    protoc_args.use_param_file("@%s")

    protoc_args.add(
        protoc_plugin_executable,
        format = "--plugin=protoc-gen-swift=%s",
    )
    protoc_args.add(generated_dir_path, format = "--swift_out=%s")
    protoc_args.add("--swift_opt=FileNaming=FullPath")
    protoc_args.add("--swift_opt=Visibility=Public")
    if module_mapping_file:
        protoc_args.add(
            module_mapping_file,
            format = "--swift_opt=ProtoPathModuleMappings=%s",
        )
    protoc_args.add_joined(
        transitive_descriptor_sets,
        join_with = ":",
        format_joined = "--descriptor_set_in=%s",
        omit_if_empty = True,
    )

    if generate_from_proto_sources:
        # ProtoCompileActionBuilder.java's XPAND_TRANSITIVE_PROTO_PATH_FLAGS
        # leaves this off also.
        if proto_source_root != ".":
            protoc_args.add(proto_source_root, format = "--proto_path=%s")

        # Follow ProtoCompileActionBuilder.java's
        # ExpandImportArgsFn::expandToCommandLine() logic and provide a mapping
        # for each file to the proto path.
        for f in direct_srcs:
            protoc_args.add("-I%s=%s" % (proto_import_path(f, proto_source_root), f.path))

    protoc_args.add_all(
        [proto_import_path(f, proto_source_root) for f in direct_srcs],
    )

    additional_command_inputs = []
    if generate_from_proto_sources:
        additional_command_inputs.extend(direct_srcs)
    if module_mapping_file:
        additional_command_inputs.append(module_mapping_file)

    # TODO(b/23975430): This should be a simple `actions.run_shell`, but until
    # the cited bug is fixed, we have to use the wrapper script.
    actions.run(
        arguments = [mkdir_args, protoc_executable_args, protoc_args],
        executable = mkdir_and_run,
        inputs = depset(
            direct = additional_command_inputs,
            transitive = [transitive_descriptor_sets],
        ),
        mnemonic = "ProtocGenSwift",
        outputs = generated_files,
        progress_message = "Generating Swift sources for {}".format(label),
        tools = [
            mkdir_and_run,
            protoc_executable,
            protoc_plugin_executable,
        ],
    )

    return generated_files

def _build_swift_proto_info_provider(
        pbswift_files,
        transitive_module_mappings,
        deps):
    """Builds the `SwiftProtoInfo` provider to propagate for a proto library.

    Args:
        pbswift_files: The `.pb.swift` files that were generated for the
            propagating target. This sequence should only contain the direct
            sources.
        transitive_module_mappings: A sequence of `structs` with `module_name`
            and `proto_file_paths` fields that denote the transitive mappings
            from `.proto` files to Swift modules.
        deps: The direct dependencies of the propagating target, from which the
            transitive sources will be computed.

    Returns:
        An instance of `SwiftProtoInfo`.
    """
    return SwiftProtoInfo(
        module_mappings = transitive_module_mappings,
        pbswift_files = depset(
            direct = pbswift_files,
            transitive = [dep[SwiftProtoInfo].pbswift_files for dep in deps],
        ),
    )

def _build_module_mapping_from_srcs(target, proto_srcs, proto_source_root):
    """Returns the sequence of module mapping `struct`s for the given sources.

    Args:
        target: The `proto_library` target whose module mapping is being
            rendered.
        proto_srcs: The `.proto` files that belong to the target.
        proto_source_root: The source root for `proto_srcs`.

    Returns:
        A string containing the module mapping for the target in protobuf text
        format.
    """

    # TODO(allevato): The previous use of f.short_path here caused problems with
    # cross-repo references; protoc-gen-swift only processes the file correctly
    # if the workspace-relative path is used (which is the same as the
    # short_path for same-repo references, so this issue had never been caught).
    # However, this implies that if two repos have protos with the same
    # workspace-relative paths, there will be a clash. Figure out what to do
    # here; it may require an update to protoc-gen-swift?
    return struct(
        module_name = swift_common.derive_module_name(target.label),
        proto_file_paths = [
            proto_import_path(f, proto_source_root)
            for f in proto_srcs
        ],
    )

def _gather_transitive_module_mappings(targets):
    """Returns the set of transitive module mappings for the given targets.

    This function eliminates duplicates among the targets so that if two or more
    targets transitively depend on the same `proto_library`, the mapping is only
    present in the sequence once.

    Args:
        targets: The targets whose module mappings should be returned.

    Returns:
        A sequence containing the transitive module mappings for the given
        targets, without duplicates.
    """
    unique_mappings = {}

    for target in targets:
        mappings = target[SwiftProtoInfo].module_mappings
        for mapping in mappings:
            module_name = mapping.module_name
            if module_name not in unique_mappings:
                unique_mappings[module_name] = mapping.proto_file_paths

    return [struct(
        module_name = module_name,
        proto_file_paths = file_paths,
    ) for module_name, file_paths in unique_mappings.items()]

def _swift_protoc_gen_aspect_impl(target, aspect_ctx):
    swift_toolchain = aspect_ctx.attr._toolchain[SwiftToolchainInfo]

    direct_srcs = _filter_out_well_known_types(
        target[ProtoInfo].direct_sources,
        target[ProtoInfo].proto_source_root,
    )

    proto_deps = [
        dep
        for dep in aspect_ctx.rule.attr.deps
        if SwiftProtoInfo in dep
    ]

    minimal_module_mappings = []
    if direct_srcs:
        minimal_module_mappings.append(
            _build_module_mapping_from_srcs(
                target,
                direct_srcs,
                target[ProtoInfo].proto_source_root,
            ),
        )
    if proto_deps:
        minimal_module_mappings.extend(
            _gather_transitive_module_mappings(proto_deps),
        )

    transitive_module_mapping_file = register_module_mapping_write_action(
        target.label.name,
        aspect_ctx.actions,
        minimal_module_mappings,
    )

    support_deps = aspect_ctx.attr._proto_support

    if direct_srcs:
        extra_features = []

        # This feature is not fully supported because the SwiftProtobuf library
        # has not yet been designed to fully support library evolution. The
        # intent of this is to allow users building distributable frameworks to
        # use Swift protos as an _implementation-only_ detail of their
        # framework, where those protos would not be exposed to clients in the
        # API. Rely on it at your own risk.
        if aspect_ctx.attr._config_emit_swiftinterface[BuildSettingInfo].value:
            extra_features.append(SWIFT_FEATURE_ENABLE_LIBRARY_EVOLUTION)
            extra_features.append(SWIFT_FEATURE_EMIT_SWIFTINTERFACE)

        # Compile the generated Swift sources and produce a static library and a
        # .swiftmodule as outputs. In addition to the other proto deps, we also
        # pass support libraries like the SwiftProtobuf runtime as deps to the
        # compile action.
        feature_configuration = swift_common.configure_features(
            ctx = aspect_ctx,
            requested_features = aspect_ctx.features + extra_features,
            swift_toolchain = swift_toolchain,
            unsupported_features = aspect_ctx.disabled_features + [
                SWIFT_FEATURE_ENABLE_TESTING,
            ],
        )

        generate_from_proto_sources = swift_common.is_enabled(
            feature_configuration = feature_configuration,
            feature_name = SWIFT_FEATURE_GENERATE_FROM_RAW_PROTO_FILES,
        )

        # Only the files for direct sources should be generated, but the
        # transitive descriptor sets are still need to be able to parse/load
        # those descriptors.
        if generate_from_proto_sources:
            # Take the transitive descriptor sets from the proto_library deps,
            # so the direct sources won't be in any descriptor sets to reduce
            # the input to the action (and what protoc has to parse).
            transitive_descriptor_sets = depset(transitive = [
                dep[ProtoInfo].transitive_descriptor_sets
                for dep in aspect_ctx.rule.attr.deps
                if ProtoInfo in dep
            ])
        else:
            transitive_descriptor_sets = target[ProtoInfo].transitive_descriptor_sets

        # Generate the Swift sources from the .proto files.
        pbswift_files = _register_pbswift_generate_action(
            target.label,
            aspect_ctx.actions,
            direct_srcs,
            target[ProtoInfo].proto_source_root,
            transitive_descriptor_sets,
            transitive_module_mapping_file,
            generate_from_proto_sources,
            aspect_ctx.executable._mkdir_and_run,
            aspect_ctx.executable._protoc,
            aspect_ctx.executable._protoc_gen_swift,
        )

        module_name = swift_common.derive_module_name(target.label)

        module_context, compilation_outputs = swift_common.compile(
            actions = aspect_ctx.actions,
            bin_dir = aspect_ctx.bin_dir,
            copts = ["-parse-as-library"],
            deps = proto_deps + support_deps,
            feature_configuration = feature_configuration,
            genfiles_dir = aspect_ctx.genfiles_dir,
            module_name = module_name,
            srcs = pbswift_files,
            swift_toolchain = swift_toolchain,
            target_name = target.label.name,
        )

        linking_context, linking_output = (
            swift_common.create_linking_context_from_compilation_outputs(
                actions = aspect_ctx.actions,
                compilation_outputs = compilation_outputs,
                feature_configuration = feature_configuration,
                label = target.label,
                linking_contexts = [
                    dep[CcInfo].linking_context
                    for dep in proto_deps + support_deps
                    if CcInfo in dep
                ],
                module_context = module_context,
                # Prevent conflicts with C++ protos in the same output
                # directory, which use the `lib{name}.a` pattern. This will
                # produce `lib{name}.swift.a` instead.
                name = "{}.swift".format(target.label.name),
                swift_toolchain = swift_toolchain,
            )
        )

        # It's bad practice to attach providers you don't own to other targets,
        # because you can't control how those targets might change in the future
        # (e.g., it could introduce a collision). This means we can't propagate
        # a `CcInfo` from this aspect nor do we want to merge the `CcInfo`
        # providers from the target's deps. Instead, the aspect returns a
        # `SwiftProtoCcInfo` provider that wraps the `CcInfo` containing the
        # Swift linking info. Then, for any subgraph of `proto_library` targets,
        # we can merge the extracted `CcInfo` providers with the regular
        # `CcInfo` providers of the support libraries (which are regular
        # `swift_library` targets), and wrap that *back* into a
        # `SwiftProtoCcInfo`. Finally, the `swift_proto_library` rule will
        # extract the `CcInfo` from the `SwiftProtoCcInfo` of its single
        # dependency and propagate that safely up the tree.
        transitive_cc_infos = (
            get_providers(proto_deps, SwiftProtoCcInfo, _extract_cc_info) +
            get_providers(support_deps, CcInfo)
        )

        # Propagate an `objc` provider if the toolchain supports Objective-C
        # interop, which ensures that the libraries get linked into
        # `apple_binary` targets properly.
        if swift_toolchain.supports_objc_interop:
            objc_infos = get_providers(
                proto_deps,
                SwiftProtoCcInfo,
                _extract_objc_info,
            ) + get_providers(support_deps, apple_common.Objc)

            objc_info = new_objc_provider(
                additional_objc_infos = (
                    objc_infos +
                    swift_toolchain.implicit_deps_providers.objc_infos
                ),
                # We pass an empty list here because we already extracted the
                # `Objc` providers from `SwiftProtoCcInfo` above.
                deps = [],
                feature_configuration = feature_configuration,
                module_context = module_context,
                libraries_to_link = [linking_output.library_to_link],
            )
        else:
            includes = None
            objc_info = None

        cc_info = CcInfo(
            compilation_context = module_context.clang.compilation_context,
            linking_context = linking_context,
        )

        providers = [
            SwiftProtoCcInfo(
                cc_info = cc_common.merge_cc_infos(
                    direct_cc_infos = [cc_info],
                    cc_infos = transitive_cc_infos,
                ),
                objc_info = objc_info,
            ),
            swift_common.create_swift_info(
                modules = [module_context],
                swift_infos = get_providers(
                    proto_deps + support_deps,
                    SwiftInfo,
                ),
            ),
        ]
    else:
        # If there are no srcs, merge the `SwiftInfo` and `CcInfo` providers and
        # propagate them. Do likewise for `apple_common.Objc` providers if the
        # toolchain supports Objective-C interop. Note that we don't need to
        # handle the runtime support libraries here; we can assume that they've
        # already been pulled in by a `proto_library` that had srcs.
        pbswift_files = []

        if swift_toolchain.supports_objc_interop:
            objc_info = apple_common.new_objc_provider(
                providers = get_providers(
                    proto_deps,
                    SwiftProtoCcInfo,
                    _extract_objc_info,
                ),
            )
        else:
            objc_info = None

        providers = [
            SwiftProtoCcInfo(
                cc_info = cc_common.merge_cc_infos(
                    cc_infos = get_providers(
                        proto_deps,
                        SwiftProtoCcInfo,
                        _extract_cc_info,
                    ),
                ),
                objc_info = objc_info,
            ),
            swift_common.create_swift_info(
                swift_infos = get_providers(proto_deps, SwiftInfo),
            ),
        ]

    providers.append(_build_swift_proto_info_provider(
        pbswift_files,
        minimal_module_mappings,
        proto_deps,
    ))

    return providers

def _extract_cc_info(proto_cc_info):
    """A map function to extract the `CcInfo` from a `SwiftProtoCcInfo`.

    Args:
        proto_cc_info: A `SwiftProtoCcInfo` provider.

    Returns:
        The `CcInfo` nested inside the `SwiftProtoCcInfo`.
    """
    return proto_cc_info.cc_info

def _extract_objc_info(proto_cc_info):
    """A map function to extract the `Objc` provider from a `SwiftProtoCcInfo`.

    Args:
        proto_cc_info: A `SwiftProtoCcInfo` provider.

    Returns:
        The `ObjcInfo` nested inside the `SwiftProtoCcInfo`.
    """
    return proto_cc_info.objc_info

swift_protoc_gen_aspect = aspect(
    attr_aspects = ["deps"],
    attrs = dicts.add(
        swift_common.toolchain_attrs(),
        swift_config_attrs(),
        {
            "_mkdir_and_run": attr.label(
                cfg = "exec",
                default = Label(
                    "@build_bazel_rules_swift//tools/mkdir_and_run",
                ),
                executable = True,
            ),
            # TODO(b/63389580): Migrate to proto_lang_toolchain.
            "_proto_support": attr.label_list(
                default = [
                    Label("@com_github_apple_swift_protobuf//:SwiftProtobuf"),
                ],
            ),
            "_protoc": attr.label(
                cfg = "exec",
                default = Label("@com_google_protobuf//:protoc"),
                executable = True,
            ),
            "_protoc_gen_swift": attr.label(
                cfg = "exec",
                default = Label("@com_github_apple_swift_protobuf//:ProtoCompilerPlugin"),
                executable = True,
            ),
        },
    ),
    doc = """\
Generates Swift artifacts for a `proto_library` target.

For each `proto_library` (more specifically, any target that propagates a
`proto` provider) to which this aspect is applied, the aspect will register
actions that generate Swift artifacts and propagate them in a `SwiftProtoInfo`
provider.

Most users should not need to use this aspect directly; it is an implementation
detail of the `swift_proto_library` rule.
""",
    fragments = ["cpp"],
    implementation = _swift_protoc_gen_aspect_impl,
)
