// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/source/source.dart';
import 'package:analyzer/src/pubspec/pubspec_validator.dart';
import 'package:analyzer/src/pubspec/pubspec_warning_code.dart';
import 'package:yaml/yaml.dart';

class MissingDependencyData {
  final List<String> addDeps;
  final List<String> addDevDeps;
  final List<String> removeDevDeps;

  MissingDependencyData(this.addDeps, this.addDevDeps, this.removeDevDeps);
}

/// A validator that computes missing dependencies and dev_dependencies based on
/// the pubspec file and the list of used dependencies and dev_dependencies
///  provided for validation.
class MissingDependencyValidator {
  /// Yaml document being validated
  final YamlNode contents;

  /// The source representing the file being validated.
  final Source source;

  /// The reporter to which errors should be reported.
  late DiagnosticReporter reporter;

  /// The resource provider used to access the file system.
  final ResourceProvider provider;

  /// The listener to record the errors.
  final RecordingDiagnosticListener recorder;

  /// A set of names of special packages that should not be added as
  /// dependencies in the `pubspec.yaml` file. For example, the flutter_gen
  /// codegen package is specified in a special `flutter` section of the
  /// `pubspec.yaml` file and not as part of the `dependencies` section.
  final Set noDepsPackages = <String>{'flutter_gen'};

  MissingDependencyValidator(this.contents, this.source, this.provider)
    : recorder = RecordingDiagnosticListener() {
    reporter = DiagnosticReporter(recorder, source);
  }

  /// Given the set of dependencies and dev dependencies used in the sources,
  /// check to see if they are present in the dependencies and dev_dependencies
  /// section of the pubspec.yaml file.
  /// Returns the list of names of the packages to be added/removed for these
  /// sections.
  List<Diagnostic> validate(Set<String> usedDeps, Set<String> usedDevDeps) {
    var contents = this.contents;
    if (contents is! YamlMap) {
      return [];
    }

    /// Return a map whose keys are the names of declared dependencies and whose
    /// values are the specifications of those dependencies. The map is extracted
    /// from the given [contents] using the given [key].
    Map<dynamic, YamlNode> getDeclaredDependencies(String key) {
      var field = contents.nodes[key];
      if (field == null || (field is YamlScalar && field.value == null)) {
        return <String, YamlNode>{};
      } else if (field is YamlMap) {
        return field.nodes;
      }
      _reportErrorForNode(
        field,
        PubspecWarningCode.DEPENDENCIES_FIELD_NOT_MAP,
        [key],
      );
      return <String, YamlNode>{};
    }

    var dependencies = getDeclaredDependencies(PubspecField.DEPENDENCIES_FIELD);
    var devDependencies = getDeclaredDependencies(
      PubspecField.DEV_DEPENDENCIES_FIELD,
    );

    var packageName = contents.nodes[PubspecField.NAME_FIELD]?.value.toString();
    // Ensure that the package itself is not listed as a dependency.
    usedDeps.remove(packageName);
    usedDevDeps.remove(packageName);
    for (var package in noDepsPackages) {
      usedDeps.remove(package);
      usedDevDeps.remove(package);
    }

    var availableDeps = [
      if (dependencies.isNotEmpty)
        for (var dep in dependencies.entries) dep.key.toString(),
    ];
    var availableDevDeps = [
      if (devDependencies.isNotEmpty)
        for (var dep in devDependencies.entries) dep.key.toString(),
    ];

    var addDeps = <String>[];
    var addDevDeps = <String>[];
    var removeDevDeps = <String>[];
    for (var name in usedDeps) {
      if (!availableDeps.contains(name)) {
        addDeps.add(name);
        if (availableDevDeps.contains(name)) {
          removeDevDeps.add(name);
        }
      }
    }
    for (var name in usedDevDeps) {
      if (!availableDevDeps.contains(name) && !availableDeps.contains(name)) {
        addDevDeps.add(name);
      }
    }
    var message =
        addDeps.isNotEmpty
            ? "${addDeps.map((s) => "'$s'").join(',')} in 'dependencies'"
            : '';
    if (addDevDeps.isNotEmpty) {
      message = message.isNotEmpty ? '$message,' : message;
      message =
          "$message ${addDevDeps.map((s) => "'$s'").join(',')} in 'dev_dependencies'";
    }
    if (addDeps.isNotEmpty || addDevDeps.isNotEmpty) {
      _reportErrorForNode(
        contents.nodes.values.first,
        PubspecWarningCode.MISSING_DEPENDENCY,
        [message],
        [],
        MissingDependencyData(addDeps, addDevDeps, removeDevDeps),
      );
    }
    return recorder.diagnostics;
  }

  /// Report an error for the given node.
  void _reportErrorForNode(
    YamlNode node,
    DiagnosticCode diagnosticCode, [
    List<Object>? arguments,
    List<DiagnosticMessage>? messages,
    Object? data,
  ]) {
    var span = node.span;
    reporter.atOffset(
      offset: span.start.offset,
      length: span.length,
      diagnosticCode: diagnosticCode,
      arguments: arguments,
      contextMessages: messages,
      data: data,
    );
  }
}
