// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:analyzer/src/dart/constant/compute.dart';
import 'package:analyzer/src/dart/constant/constant_verifier.dart';
import 'package:analyzer/src/dart/constant/evaluation.dart';
import 'package:analyzer/src/dart/constant/potentially_constant.dart';
import 'package:analyzer/src/dart/constant/utilities.dart';
import 'package:analyzer/src/error/codes.dart';

/// A diagnostic listener that only records whether any constant-related
/// diagnostics have been reported.
class _ConstantDiagnosticListener extends DiagnosticListener {
  /// A flag indicating whether any constant-related diagnostics have been
  /// reported to this listener.
  bool hasConstError = false;

  @override
  void onError(Diagnostic diagnostic) {
    DiagnosticCode diagnosticCode = diagnostic.diagnosticCode;
    if (diagnosticCode is CompileTimeErrorCode) {
      switch (diagnosticCode) {
        case CompileTimeErrorCode
            .CONST_CONSTRUCTOR_CONSTANT_FROM_DEFERRED_LIBRARY:
        case CompileTimeErrorCode
            .CONST_CONSTRUCTOR_WITH_FIELD_INITIALIZED_BY_NON_CONST:
        case CompileTimeErrorCode.CONST_EVAL_EXTENSION_METHOD:
        case CompileTimeErrorCode.CONST_EVAL_EXTENSION_TYPE_METHOD:
        case CompileTimeErrorCode.CONST_EVAL_METHOD_INVOCATION:
        case CompileTimeErrorCode.CONST_EVAL_PROPERTY_ACCESS:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_BOOL:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_BOOL_INT:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_BOOL_NUM_STRING:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_INT:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_NUM:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_NUM_STRING:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_STRING:
        case CompileTimeErrorCode.CONST_EVAL_THROWS_EXCEPTION:
        case CompileTimeErrorCode.CONST_EVAL_THROWS_IDBZE:
        case CompileTimeErrorCode.CONST_EVAL_FOR_ELEMENT:
        case CompileTimeErrorCode.CONST_MAP_KEY_NOT_PRIMITIVE_EQUALITY:
        case CompileTimeErrorCode.CONST_SET_ELEMENT_NOT_PRIMITIVE_EQUALITY:
        case CompileTimeErrorCode.CONST_TYPE_PARAMETER:
        case CompileTimeErrorCode.CONST_WITH_NON_CONST:
        case CompileTimeErrorCode.CONST_WITH_NON_CONSTANT_ARGUMENT:
        case CompileTimeErrorCode.CONST_WITH_TYPE_PARAMETERS:
        case CompileTimeErrorCode
            .CONST_WITH_TYPE_PARAMETERS_CONSTRUCTOR_TEAROFF:
        case CompileTimeErrorCode.INVALID_CONSTANT:
        case CompileTimeErrorCode.MISSING_CONST_IN_LIST_LITERAL:
        case CompileTimeErrorCode.MISSING_CONST_IN_MAP_LITERAL:
        case CompileTimeErrorCode.MISSING_CONST_IN_SET_LITERAL:
        case CompileTimeErrorCode.NON_BOOL_CONDITION:
        case CompileTimeErrorCode.NON_CONSTANT_LIST_ELEMENT:
        case CompileTimeErrorCode.NON_CONSTANT_MAP_ELEMENT:
        case CompileTimeErrorCode.NON_CONSTANT_MAP_KEY:
        case CompileTimeErrorCode.NON_CONSTANT_MAP_VALUE:
        case CompileTimeErrorCode.NON_CONSTANT_RECORD_FIELD:
        case CompileTimeErrorCode.NON_CONSTANT_SET_ELEMENT:
          hasConstError = true;
      }
    }
  }
}

extension AstNodeExtension on AstNode {
  /// Whether [ConstantVerifier] reports an error when computing the value of
  /// `this` as a constant.
  bool get hasConstantVerifierError {
    var unitNode = thisOrAncestorOfType<CompilationUnitImpl>();
    var unitFragment = unitNode?.declaredFragment;
    if (unitFragment == null) return false;

    var libraryElement = unitFragment.element;
    var declaredVariables = libraryElement.session.declaredVariables;

    var dependenciesFinder = ConstantExpressionsDependenciesFinder();
    accept(dependenciesFinder);
    computeConstants(
      declaredVariables: declaredVariables,
      constants: dependenciesFinder.dependencies.toList(),
      featureSet: libraryElement.featureSet,
      configuration: ConstantEvaluationConfiguration(),
    );

    var listener = _ConstantDiagnosticListener();
    var errorReporter = DiagnosticReporter(listener, unitFragment.source);

    accept(ConstantVerifier(errorReporter, libraryElement, declaredVariables));
    return listener.hasConstError;
  }
}

extension ConstructorDeclarationExtension on ConstructorDeclaration {
  bool get canBeConst {
    var element = declaredFragment!.element;

    var classElement = element.enclosingElement;
    if (classElement is ClassElement && classElement.hasNonFinalField) {
      return false;
    }

    var oldKeyword = constKeyword;
    var self = this as ConstructorDeclarationImpl;
    try {
      temporaryConstConstructorElements[element] = true;
      self.constKeyword = KeywordToken(Keyword.CONST, offset);
      return !hasConstantVerifierError;
    } finally {
      temporaryConstConstructorElements[element] = null;
      self.constKeyword = oldKeyword;
    }
  }
}
