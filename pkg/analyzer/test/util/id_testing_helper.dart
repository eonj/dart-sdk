// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// TODO(johnniwinther): .
// TODO(paulberry): Use the code for extraction of test data from
// annotated code from CFE.

import 'package:_fe_analyzer_shared/src/testing/annotated_code_helper.dart';
import 'package:_fe_analyzer_shared/src/testing/id.dart';
import 'package:_fe_analyzer_shared/src/testing/id_testing.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart' hide Annotation;
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/memory_file_system.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/testing_data.dart';
import 'package:analyzer/src/test_utilities/mock_sdk.dart';
import 'package:analyzer/src/utilities/extensions/diagnostic.dart';
import 'package:analyzer_testing/utilities/extensions/resource_provider.dart';

/// Test configuration used for testing the analyzer without experiments.
final TestConfig analyzerDefaultConfig = TestConfig(
  analyzerMarker,
  'analyzer without experiments',
  featureSet: FeatureSet.latestLanguageVersion(),
);

/// A fake absolute directory used as the root of a memory-file system in ID
/// tests.
Uri _defaultDir = Uri.parse('file:///a/b/c/');

/// Creates the testing URI used for [fileName] in annotated tests.
Uri createUriForFileName(String fileName) => _toTestUri(fileName);

void onFailure(String message) {
  throw StateError(message);
}

/// Runs [dataComputer] on [testData] for all [testedConfigs].
///
/// Returns `true` if an error was encountered.
Future<Map<String, TestResult<T>>> runTest<T>(
  MarkerOptions markerOptions,
  TestData testData,
  DataComputer<T> dataComputer,
  List<TestConfig> testedConfigs, {
  required bool testAfterFailures,
  bool forUserLibrariesOnly = true,
  Iterable<Id> globalIds = const <Id>[],
  required void Function(String message) onFailure,
  Map<String, List<String>>? skipMap,
}) async {
  for (TestConfig config in testedConfigs) {
    if (!testData.expectedMaps.containsKey(config.marker)) {
      throw ArgumentError(
        "Unexpected test marker '${config.marker}'. "
        "Supported markers: ${testData.expectedMaps.keys}.",
      );
    }
  }

  Map<String, TestResult<T>> results = {};
  for (TestConfig config in testedConfigs) {
    if (skipForConfig(testData.name, config.marker, skipMap)) {
      continue;
    }
    results[config.marker] = await runTestForConfig(
      markerOptions,
      testData,
      dataComputer,
      config,
      fatalErrors: !testAfterFailures,
      onFailure: onFailure,
    );
  }
  return results;
}

/// Creates a test runner for [dataComputer] on [testedConfigs].
RunTestFunction<T> runTestFor<T>(
  DataComputer<T> dataComputer,
  List<TestConfig> testedConfigs,
) {
  return (
    MarkerOptions markerOptions,
    TestData testData, {
    required bool testAfterFailures,
    bool? verbose,
    bool? succinct,
    bool? printCode,
    Map<String, List<String>>? skipMap,
    Uri? nullUri,
  }) {
    return runTest(
      markerOptions,
      testData,
      dataComputer,
      testedConfigs,
      testAfterFailures: testAfterFailures,
      onFailure: onFailure,
      skipMap: skipMap,
    );
  };
}

/// Runs [dataComputer] on [testData] for [config].
///
/// Returns `true` if an error was encountered.
Future<TestResult<T>> runTestForConfig<T>(
  MarkerOptions markerOptions,
  TestData testData,
  DataComputer<T> dataComputer,
  TestConfig config, {
  bool fatalErrors = true,
  required void Function(String message) onFailure,
  Map<String, List<String>>? skipMap,
}) async {
  MemberAnnotations<IdValue> memberAnnotations =
      testData.expectedMaps[config.marker]!;

  var resourceProvider = MemoryResourceProvider();
  var testFiles = <_TestFile>[];
  for (var entry in testData.memorySourceFiles.entries) {
    var uri = _toTestUri(entry.key);
    var path = ResourceProviderExtension(
      resourceProvider,
    ).convertPath(uri.path);
    var file = resourceProvider.getFile(path);
    testFiles.add(_TestFile(uri: uri, file: file));
    file.writeAsStringSync(entry.value);
  }

  var sdkRoot = resourceProvider.newFolder(
    ResourceProviderExtension(resourceProvider).convertPath('/sdk'),
  );
  createMockSdk(resourceProvider: resourceProvider, root: sdkRoot);

  var contextCollection = AnalysisContextCollectionImpl(
    includedPaths: testFiles.map((e) => e.path).toList(),
    resourceProvider: resourceProvider,
    retainDataForTesting: true,
    sdkPath: sdkRoot.path,
    updateAnalysisOptions3: ({required analysisOptions, required sdk}) {
      analysisOptions.contextFeatures = config.featureSet;
    },
  );
  var analysisContext = contextCollection.contexts.single;
  var analysisSession = analysisContext.currentSession;
  var driver = analysisContext.driver;

  Map<Uri, Map<Id, ActualData<T>>> actualMaps = <Uri, Map<Id, ActualData<T>>>{};
  Map<Id, ActualData<T>> globalData = <Id, ActualData<T>>{};

  Map<Id, ActualData<T>> actualMapFor(Uri uri) {
    return actualMaps.putIfAbsent(uri, () => <Id, ActualData<T>>{});
  }

  var results = <Uri, ResolvedUnitResult>{};
  for (var testFile in testFiles) {
    var testUri = testFile.uri;
    var result = await analysisSession.getResolvedUnit(testFile.path);
    result as ResolvedUnitResult;
    var errors = result.diagnostics.errors;
    if (errors.isNotEmpty) {
      if (dataComputer.supportsErrors) {
        var diagnosticMap = <int, List<Diagnostic>>{};
        for (var error in errors) {
          var offset = error.offset;
          if (offset == 0 || offset < 0) {
            // Position errors without offset in the begin of the file.
            offset = 0;
          }
          (diagnosticMap[offset] ??= <Diagnostic>[]).add(error);
        }
        diagnosticMap.forEach((offset, errors) {
          var id = NodeId(offset, IdKind.error);
          var data = dataComputer.computeErrorData(
            config,
            driver.testingData!,
            id,
            errors,
          );
          if (data != null) {
            Map<Id, ActualData<T>> actualMap = actualMapFor(testUri);
            actualMap[id] = ActualData<T>(id, data, testUri, offset, errors);
          }
        });
      } else {
        String formatError(Diagnostic e) {
          var locationInfo = result.unit.lineInfo.getLocation(e.offset);
          return '$locationInfo: ${e.diagnosticCode}: ${e.message}';
        }

        onFailure('Errors found:\n  ${errors.map(formatError).join('\n  ')}');
        return TestResult<T>.erroneous();
      }
    }
    results[testUri] = result;
  }

  results.forEach((testUri, result) {
    dataComputer.computeUnitData(
      driver.testingData!,
      result.unit,
      actualMapFor(testUri),
    );
  });
  var compiledData = AnalyzerCompiledData<T>(
    testData.code,
    testData.entryPoint,
    actualMaps,
    globalData,
  );
  return checkCode(
    markerOptions,
    config.marker,
    config.name,
    testData,
    memberAnnotations,
    compiledData,
    dataComputer.dataValidator,
    fatalErrors: fatalErrors,
    onFailure: onFailure,
  );
}

/// Convert relative file paths into an absolute Uri as expected by the test
/// helpers.
Uri _toTestUri(String relativePath) => _defaultDir.resolve(relativePath);

class AnalyzerCompiledData<T> extends CompiledData<T> {
  // TODO(johnniwinther): .
  // TODO(paulberry): Maybe this should have access to the [ResolvedUnitResult] instead.
  final Map<Uri, AnnotatedCode> code;

  AnalyzerCompiledData(
    this.code,
    Uri mainUri,
    Map<Uri, Map<Id, ActualData<T>>> actualMaps,
    Map<Id, ActualData<T>> globalData,
  ) : super(mainUri, actualMaps, globalData);

  @override
  int getOffsetFromId(Id id, Uri uri) {
    if (id is NodeId) {
      return id.value;
    } else if (id is MemberId) {
      var className = id.className;
      var name = id.memberName;
      var unit =
          parseString(
            content: code[uri]!.sourceCode,
            throwIfDiagnostics: false,
          ).unit;
      if (className != null) {
        for (var declaration in unit.declarations) {
          if (declaration is ClassDeclaration &&
              declaration.name.lexeme == className) {
            for (var member in declaration.members) {
              if (member is ConstructorDeclaration) {
                if (member.name!.lexeme == name) {
                  return member.offset;
                }
              } else if (member is FieldDeclaration) {
                for (var variable in member.fields.variables) {
                  if (variable.name.lexeme == name) {
                    return variable.offset;
                  }
                }
              } else if (member is MethodDeclaration) {
                if (member.name.lexeme == name) {
                  return member.offset;
                }
              }
            }
            // Use class offset for members not declared in the class.
            return declaration.offset;
          }
        }
        return 0;
      }
      for (var declaration in unit.declarations) {
        if (declaration is FunctionDeclaration) {
          if (declaration.name.lexeme == name) {
            return declaration.offset;
          }
        } else if (declaration is TopLevelVariableDeclaration) {
          for (var variable in declaration.variables.variables) {
            if (variable.name.lexeme == name) {
              return variable.offset;
            }
          }
        }
      }
      return 0;
    } else if (id is ClassId) {
      var className = id.className;
      var unit =
          parseString(
            content: code[uri]!.sourceCode,
            throwIfDiagnostics: false,
          ).unit;
      for (var declaration in unit.declarations) {
        if (declaration is ClassDeclaration &&
            declaration.name.lexeme == className) {
          return declaration.offset;
        }
      }
      return 0;
    } else {
      throw StateError('Unexpected id ${id.runtimeType}');
    }
  }

  @override
  void reportError(
    Uri uri,
    int offset,
    String message, {
    bool succinct = false,
  }) {
    print('$offset: $message');
  }
}

abstract class DataComputer<T> {
  const DataComputer();

  DataInterpreter<T> get dataValidator;

  /// Returns `true` if this data computer supports tests with compile-time
  /// errors.
  ///
  /// Unsuccessful compilation might leave the compiler in an inconsistent
  /// state, so this testing feature is opt-in.
  bool get supportsErrors => false;

  /// Returns data corresponding to [diagnostics].
  T? computeErrorData(
    TestConfig config,
    TestingData testingData,
    Id id,
    List<Diagnostic> diagnostics,
  ) => null;

  /// Computes a data mapping for [unit].
  ///
  /// Fills [actualMap] with the data.
  void computeUnitData(
    TestingData testingData,
    CompilationUnit unit,
    Map<Id, ActualData<T>> actualMap,
  );
}

class TestConfig {
  final String marker;
  final String name;
  final FeatureSet featureSet;

  TestConfig(this.marker, this.name, {FeatureSet? featureSet})
    : featureSet = featureSet ?? FeatureSet.latestLanguageVersion();
}

class _TestFile {
  final Uri uri;
  final File file;

  _TestFile({required this.uri, required this.file});

  String get path => file.path;
}
