// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:_fe_analyzer_shared/src/scanner/string_canonicalizer.dart';
import 'package:_fe_analyzer_shared/src/type_inference/type_analyzer.dart'
    as shared;
import 'package:_fe_analyzer_shared/src/type_inference/type_analyzer_operations.dart'
    as shared;
import 'package:_fe_analyzer_shared/src/types/shared_type.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/source/source.dart';
import 'package:analyzer/src/dart/analysis/experiments.dart';
import 'package:analyzer/src/dart/analysis/session.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:analyzer/src/dart/constant/compute.dart';
import 'package:analyzer/src/dart/constant/evaluation.dart';
import 'package:analyzer/src/dart/constant/value.dart';
import 'package:analyzer/src/dart/element/display_string_builder.dart';
import 'package:analyzer/src/dart/element/field_name_non_promotability_info.dart';
import 'package:analyzer/src/dart/element/inheritance_manager3.dart';
import 'package:analyzer/src/dart/element/member.dart';
import 'package:analyzer/src/dart/element/name_union.dart';
import 'package:analyzer/src/dart/element/scope.dart';
import 'package:analyzer/src/dart/element/since_sdk_version.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/element/type_algebra.dart';
import 'package:analyzer/src/dart/element/type_provider.dart';
import 'package:analyzer/src/dart/element/type_system.dart';
import 'package:analyzer/src/dart/resolver/scope.dart'
    show Namespace, NamespaceBuilder;
import 'package:analyzer/src/error/inference_error.dart';
import 'package:analyzer/src/fine/annotations.dart';
import 'package:analyzer/src/fine/library_manifest.dart';
import 'package:analyzer/src/fine/requirements.dart';
import 'package:analyzer/src/generated/engine.dart' show AnalysisContext;
import 'package:analyzer/src/generated/source.dart' show DartUriResolver;
import 'package:analyzer/src/generated/utilities_collection.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:analyzer/src/summary2/ast_binary_tokens.dart';
import 'package:analyzer/src/summary2/data_reader.dart';
import 'package:analyzer/src/summary2/data_writer.dart';
import 'package:analyzer/src/summary2/export.dart';
import 'package:analyzer/src/summary2/informative_data.dart';
import 'package:analyzer/src/summary2/reference.dart';
import 'package:analyzer/src/util/file_paths.dart' as file_paths;
import 'package:analyzer/src/utilities/extensions/collection.dart';
import 'package:analyzer/src/utilities/extensions/element.dart';
import 'package:analyzer/src/utilities/extensions/object.dart';
import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

// TODO(fshcheglov): Remove after third_party/pkg/dartdoc stops using it.
// https://github.com/dart-lang/dartdoc/issues/4066
@Deprecated('Use ConstVariableFragment instead')
typedef ConstVariableElement = ConstVariableFragment;

abstract class AnnotatableElementImpl implements ElementImpl, Annotatable {
  @override
  MetadataImpl get metadata;
}

abstract class AnnotatableFragmentImpl implements FragmentImpl, Annotatable {
  @override
  abstract MetadataImpl metadata;
}

/// Shared implementation for an augmentable [Fragment].
mixin AugmentableFragment on FragmentImpl {
  bool get isAugmentation {
    return hasModifier(Modifier.AUGMENTATION);
  }

  set isAugmentation(bool value) {
    setModifier(Modifier.AUGMENTATION, value);
  }
}

class BindPatternVariableElementImpl extends PatternVariableElementImpl
    implements BindPatternVariableElement {
  BindPatternVariableElementImpl(super._wrappedElement);

  @override
  BindPatternVariableFragmentImpl get firstFragment =>
      super.firstFragment as BindPatternVariableFragmentImpl;

  @override
  List<BindPatternVariableFragmentImpl> get fragments {
    return [
      for (
        BindPatternVariableFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  /// Whether this variable clashes with another pattern variable with the same
  /// name within the same pattern.
  bool get isDuplicate => _wrappedElement.isDuplicate;

  /// Set whether this variable clashes with another pattern variable with the
  /// same name within the same pattern.
  set isDuplicate(bool value) => _wrappedElement.isDuplicate = value;

  DeclaredVariablePatternImpl get node => _wrappedElement.node;

  @override
  BindPatternVariableFragmentImpl get _wrappedElement =>
      super._wrappedElement as BindPatternVariableFragmentImpl;
}

class BindPatternVariableFragmentImpl extends PatternVariableFragmentImpl
    implements BindPatternVariableFragment {
  final DeclaredVariablePatternImpl node;

  /// This flag is set to `true` if this variable clashes with another
  /// pattern variable with the same name within the same pattern.
  bool isDuplicate = false;

  BindPatternVariableFragmentImpl({
    required this.node,
    required super.name2,
    required super.nameOffset,
  }) {
    _element2 = BindPatternVariableElementImpl(this);
  }

  @override
  BindPatternVariableElementImpl get element =>
      super.element as BindPatternVariableElementImpl;

  @override
  BindPatternVariableFragmentImpl? get nextFragment =>
      super.nextFragment as BindPatternVariableFragmentImpl?;

  @override
  BindPatternVariableFragmentImpl? get previousFragment =>
      super.previousFragment as BindPatternVariableFragmentImpl?;
}

@elementClass
class ClassElementImpl extends InterfaceElementImpl implements ClassElement {
  @override
  @trackedIncludedIntoId
  final Reference reference;

  final ClassFragmentImpl _firstFragment;

  ClassElementImpl(this.reference, this._firstFragment) {
    reference.element = this;
    firstFragment.augmentedInternal = this;
  }

  /// If we can find all possible subtypes of this class, return them.
  ///
  /// If the class is final, all its subtypes are declared in this library.
  ///
  /// If the class is sealed, and all its subtypes are either final or sealed,
  /// then these subtypes are all subtypes that are possible.
  @trackedDirectlyExpensive
  List<InterfaceTypeImpl>? get allSubtypes {
    globalResultRequirements?.record_classElement_allSubtypes(element: this);

    if (isFinal) {
      var result = <InterfaceTypeImpl>[];
      for (var element in library2.children2) {
        if (element is InterfaceElementImpl && element != this) {
          var elementThis = element.thisType;
          if (elementThis.asInstanceOf2(this) != null) {
            result.add(elementThis);
          }
        }
      }
      return result;
    }

    if (isSealed) {
      var result = <InterfaceTypeImpl>[];
      for (var element in library2.children2) {
        if (element is! InterfaceElementImpl || identical(element, this)) {
          continue;
        }

        var elementThis = element.thisType;
        if (elementThis.asInstanceOf2(this) == null) {
          continue;
        }

        switch (element) {
          case ClassElementImpl _:
            if (element.isFinal || element.isSealed) {
              result.add(elementThis);
            } else {
              return null;
            }
          case EnumElement _:
            result.add(elementThis);
          case MixinElement _:
            return null;
        }
      }
      return result;
    }

    return null;
  }

  @override
  @trackedDirectlyDisable
  ClassFragmentImpl get firstFragment {
    globalResultRequirements?.record_disable(this, 'firstFragment');
    return _firstFragment;
  }

  @override
  @trackedDirectlyDisable
  List<ClassFragmentImpl> get fragments {
    globalResultRequirements?.record_disable(this, 'fragments');
    return [
      for (
        ClassFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  @trackedDirectlyExpensive
  bool get hasNonFinalField {
    globalResultRequirements?.record_classElement_hasNonFinalField(
      element: this,
    );

    var classesToVisit = <InterfaceElementImpl>[];
    var visitedClasses = <InterfaceElementImpl>{};
    classesToVisit.add(this);
    while (classesToVisit.isNotEmpty) {
      var currentElement = classesToVisit.removeAt(0);
      if (visitedClasses.add(currentElement)) {
        // check fields
        for (var field in currentElement.fields) {
          if (!field.isFinal &&
              !field.isConst &&
              !field.isStatic &&
              !field.isSynthetic) {
            return true;
          }
        }
        // check mixins
        for (var mixinType in currentElement.mixins) {
          classesToVisit.add(mixinType.element3);
        }
        // check super
        var supertype = currentElement.supertype;
        if (supertype != null) {
          classesToVisit.add(supertype.element3);
        }
      }
    }
    // not found
    return false;
  }

  @override
  @trackedIncludedIntoId
  bool get isAbstract => firstFragment.isAbstract;

  @override
  @trackedIncludedIntoId
  bool get isBase => firstFragment.isBase;

  @override
  @trackedIncludedIntoId
  bool get isConstructable => firstFragment.isConstructable;

  @override
  @trackedIncludedIntoId
  bool get isDartCoreEnum => firstFragment.isDartCoreEnum;

  @override
  @trackedIncludedIntoId
  bool get isDartCoreObject => firstFragment.isDartCoreObject;

  @trackedIncludedIntoId
  bool get isDartCoreRecord {
    return name3 == 'Record' && library2.isDartCore;
  }

  @trackedDirectlyExpensive
  bool get isEnumLike {
    globalResultRequirements?.record_classElement_isEnumLike(element: this);

    // Must be a concrete class.
    if (isAbstract) {
      return false;
    }

    // With only private non-factory constructors.
    for (var constructor in constructors) {
      if (constructor.isPublic || constructor.isFactory) {
        return false;
      }
    }

    // With 2+ static const fields with the type of this class.
    var numberOfElements = 0;
    for (var field in fields) {
      if (field.isStatic && field.isConst && field.type == thisType) {
        numberOfElements++;
      }
    }
    if (numberOfElements < 2) {
      return false;
    }

    // No subclasses in the library.
    for (var class_ in library2.classes) {
      if (class_.supertype?.element3 == this) {
        return false;
      }
    }

    return true;
  }

  @override
  @trackedIncludedIntoId
  bool get isExhaustive => firstFragment.isExhaustive;

  @override
  @trackedIncludedIntoId
  bool get isFinal => firstFragment.isFinal;

  @override
  @trackedIncludedIntoId
  bool get isInterface => firstFragment.isInterface;

  @override
  @trackedIncludedIntoId
  bool get isMixinApplication => firstFragment.isMixinApplication;

  @override
  @trackedIncludedIntoId
  bool get isMixinClass => firstFragment.isMixinClass;

  @override
  @trackedIncludedIntoId
  bool get isSealed => firstFragment.isSealed;

  @override
  @trackedIncludedIntoId
  bool get isValidMixin => firstFragment.isValidMixin;

  @override
  @trackedDirectlyDisable
  T? accept2<T>(ElementVisitor2<T> visitor) {
    globalResultRequirements?.record_disable(this, 'accept2');
    return visitor.visitClassElement(this);
  }

  @override
  @trackedIndirectly
  bool isExtendableIn(LibraryElement library) {
    if (library == library2) {
      return true;
    }
    return !isInterface && !isFinal && !isSealed;
  }

  @Deprecated('Use isExtendableIn instead')
  @override
  bool isExtendableIn2(LibraryElement library) {
    return isExtendableIn(library);
  }

  @override
  @trackedIndirectly
  bool isImplementableIn(LibraryElement library) {
    if (library == library2) {
      return true;
    }
    return !isBase && !isFinal && !isSealed;
  }

  @Deprecated('Use isImplementableIn instead')
  @override
  bool isImplementableIn2(LibraryElement library) {
    return isImplementableIn(library);
  }

  @override
  @trackedIndirectly
  bool isMixableIn(LibraryElement library) {
    if (library == library2) {
      return true;
    } else if (library2.featureSet.isEnabled(Feature.class_modifiers)) {
      return isMixinClass && !isInterface && !isFinal && !isSealed;
    }
    return true;
  }

  @Deprecated('Use isMixableIn instead')
  @override
  bool isMixableIn2(LibraryElement library) {
    return isMixableIn(library);
  }
}

/// An [InterfaceFragmentImpl] which is a class.
class ClassFragmentImpl extends ClassOrMixinFragmentImpl
    implements ClassFragment {
  late ClassElementImpl augmentedInternal;

  /// Initialize a newly created class element to have the given [name] at the
  /// given [offset] in the file that contains the declaration of this element.
  ClassFragmentImpl({required super.name2, required super.nameOffset});

  @override
  ClassElementImpl get element {
    _ensureReadResolution();
    return augmentedInternal;
  }

  bool get hasExtendsClause {
    return hasModifier(Modifier.HAS_EXTENDS_CLAUSE);
  }

  set hasExtendsClause(bool value) {
    setModifier(Modifier.HAS_EXTENDS_CLAUSE, value);
  }

  bool get hasGenerativeConstConstructor {
    return constructors.any((c) => !c.isFactory && c.isConst);
  }

  bool get isAbstract {
    return hasModifier(Modifier.ABSTRACT);
  }

  set isAbstract(bool isAbstract) {
    setModifier(Modifier.ABSTRACT, isAbstract);
  }

  @override
  bool get isBase {
    return hasModifier(Modifier.BASE);
  }

  bool get isConstructable => !isSealed && !isAbstract;

  bool get isDartCoreEnum {
    return name2 == 'Enum' && library.isDartCore;
  }

  bool get isDartCoreObject {
    return name2 == 'Object' && library.isDartCore;
  }

  bool get isDartCoreRecord {
    return name2 == 'Record' && library.isDartCore;
  }

  bool get isExhaustive => isSealed;

  bool get isFinal {
    return hasModifier(Modifier.FINAL);
  }

  set isFinal(bool isFinal) {
    setModifier(Modifier.FINAL, isFinal);
  }

  bool get isInterface {
    return hasModifier(Modifier.INTERFACE);
  }

  set isInterface(bool isInterface) {
    setModifier(Modifier.INTERFACE, isInterface);
  }

  bool get isMixinApplication {
    return hasModifier(Modifier.MIXIN_APPLICATION);
  }

  /// Set whether this class is a mixin application.
  set isMixinApplication(bool isMixinApplication) {
    setModifier(Modifier.MIXIN_APPLICATION, isMixinApplication);
  }

  bool get isMixinClass {
    return hasModifier(Modifier.MIXIN_CLASS);
  }

  set isMixinClass(bool isMixinClass) {
    setModifier(Modifier.MIXIN_CLASS, isMixinClass);
  }

  bool get isSealed {
    return hasModifier(Modifier.SEALED);
  }

  set isSealed(bool isSealed) {
    setModifier(Modifier.SEALED, isSealed);
  }

  bool get isValidMixin {
    var supertype = this.supertype;
    if (supertype != null && !supertype.isDartCoreObject) {
      return false;
    }
    for (var constructor in constructors) {
      if (!constructor.isSynthetic && !constructor.isFactory) {
        return false;
      }
    }
    return true;
  }

  @override
  ElementKind get kind => ElementKind.CLASS;

  @override
  ClassFragmentImpl? get nextFragment {
    return super.nextFragment as ClassFragmentImpl?;
  }

  @override
  ClassFragmentImpl? get previousFragment {
    return super.previousFragment as ClassFragmentImpl?;
  }

  void addFragment(ClassFragmentImpl fragment) {
    fragment.augmentedInternal = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeClassElement(this);
  }

  @override
  void _buildMixinAppConstructors() {
    // Do nothing if not a mixin application.
    if (!isMixinApplication) {
      return;
    }

    var superType = supertype;
    if (superType == null) {
      // Shouldn't ever happen, since the only classes with no supertype are
      // Object and mixins, and they aren't a mixin application. But for
      // safety's sake just assume an empty list.
      assert(false);
      _constructors = <ConstructorFragmentImpl>[];
      return;
    }

    // Assign to break a possible infinite recursion during computing.
    _constructors = const <ConstructorFragmentImpl>[];

    var superElement2 = superType.element3 as ClassElementImpl;
    var superElement = superElement2.firstFragment;

    var constructorsToForward = superElement.constructors
        .where((constructor) => constructor.asElement2.isAccessibleIn2(library))
        .where((constructor) => !constructor.isFactory)
        .toList(growable: false);

    // Figure out the type parameter substitution we need to perform in order
    // to produce constructors for this class.  We want to be robust in the
    // face of errors, so drop any extra type arguments and fill in any missing
    // ones with `dynamic`.
    var superClassParameters = superElement.typeParameters;
    List<DartType> argumentTypes = List<DartType>.filled(
      superClassParameters.length,
      DynamicTypeImpl.instance,
    );
    for (int i = 0; i < superType.typeArguments.length; i++) {
      if (i >= argumentTypes.length) {
        break;
      }
      argumentTypes[i] = superType.typeArguments[i];
    }
    var substitution = Substitution.fromPairs(
      superClassParameters,
      argumentTypes,
    );

    bool typeHasInstanceVariables(InterfaceTypeImpl type) =>
        type.element3.fields.any((e) => !e.isSynthetic);

    // Now create an implicit constructor for every constructor found above,
    // substituting type parameters as appropriate.
    _constructors = constructorsToForward
        .map((superclassConstructor) {
          var name = superclassConstructor.name2;
          var implicitConstructorFragment = ConstructorFragmentImpl(
            name2: name,
            nameOffset: -1,
          );
          implicitConstructorFragment.isSynthetic = true;
          implicitConstructorFragment.typeName = name2;

          var hasMixinWithInstanceVariables = mixins.any(
            typeHasInstanceVariables,
          );
          implicitConstructorFragment.isConst =
              superclassConstructor.isConst && !hasMixinWithInstanceVariables;
          var superParameters = superclassConstructor.parameters;
          int count = superParameters.length;
          var argumentsForSuperInvocation = <ExpressionImpl>[];
          if (count > 0) {
            var implicitParameters = <FormalParameterFragmentImpl>[];
            for (int i = 0; i < count; i++) {
              var superParameter = superParameters[i];
              FormalParameterFragmentImpl implicitParameter;
              if (superParameter is ConstVariableFragment) {
                var constVariable = superParameter as ConstVariableFragment;
                implicitParameter = DefaultParameterFragmentImpl(
                  nameOffset: -1,
                  name2: superParameter.name2,
                  nameOffset2: null,
                  parameterKind: superParameter.parameterKind,
                )..constantInitializer = constVariable.constantInitializer;
              } else {
                implicitParameter = FormalParameterFragmentImpl(
                  nameOffset: -1,
                  name2: superParameter.name2,
                  nameOffset2: null,
                  parameterKind: superParameter.parameterKind,
                );
              }
              implicitParameter.isConst = superParameter.isConst;
              implicitParameter.isFinal = superParameter.isFinal;
              implicitParameter.isSynthetic = true;
              implicitParameter.type = substitution.substituteType(
                superParameter.type,
              );
              implicitParameters.add(implicitParameter);
              argumentsForSuperInvocation.add(
                SimpleIdentifierImpl(
                    token: StringToken(
                      TokenType.STRING,
                      implicitParameter.name2 ?? '',
                      -1,
                    ),
                  )
                  ..element = implicitParameter.asElement2
                  ..setPseudoExpressionStaticType(implicitParameter.type),
              );
            }
            implicitConstructorFragment.parameters =
                implicitParameters.toFixedList();
          }
          implicitConstructorFragment.enclosingElement3 = this;
          // TODO(scheglov): Why do we manually map parameters types above?
          implicitConstructorFragment.superConstructor = ConstructorMember.from(
            superclassConstructor,
            superType,
          );

          var isNamed = superclassConstructor.name2 != 'new';
          var superInvocation = SuperConstructorInvocationImpl(
            superKeyword: Tokens.super_(),
            period: isNamed ? Tokens.period() : null,
            constructorName:
                isNamed
                    ? (SimpleIdentifierImpl(
                      token: StringToken(
                        TokenType.STRING,
                        superclassConstructor.name2,
                        -1,
                      ),
                    )..element = superclassConstructor.asElement2)
                    : null,
            argumentList: ArgumentListImpl(
              leftParenthesis: Tokens.openParenthesis(),
              arguments: argumentsForSuperInvocation,
              rightParenthesis: Tokens.closeParenthesis(),
            ),
          );
          AstNodeImpl.linkNodeTokens(superInvocation);
          superInvocation.element = superclassConstructor.asElement2;
          implicitConstructorFragment.constantInitializers = [superInvocation];

          return implicitConstructorFragment;
        })
        .toList(growable: false);

    if (element.firstFragment == this) {
      element.constructors =
          _constructors.map((fragment) {
            return ConstructorElementImpl(
              name3: fragment.name2,
              reference: element.reference
                  .getChild('@constructor')
                  .getChild(fragment.name2),
              firstFragment: fragment,
            );
          }).toList();
    }
  }
}

abstract class ClassOrMixinFragmentImpl extends InterfaceFragmentImpl {
  /// Initialize a newly created class element to have the given [name] at the
  /// given [offset] in the file that contains the declaration of this element.
  ClassOrMixinFragmentImpl({required super.name2, required super.nameOffset});

  bool get isBase {
    return hasModifier(Modifier.BASE);
  }

  set isBase(bool isBase) {
    setModifier(Modifier.BASE, isBase);
  }
}

class ConstantInitializerImpl implements ConstantInitializer {
  @override
  final VariableFragmentImpl fragment;

  @override
  final ExpressionImpl expression;

  /// The cached result of [evaluate].
  Constant? _evaluationResult;

  ConstantInitializerImpl({required this.fragment, required this.expression});

  @override
  DartObject? evaluate() {
    if (_evaluationResult case DartObjectImpl result) {
      return result;
    }
    // TODO(scheglov): implement it
    throw UnimplementedError();
  }
}

/// A `LocalVariableElement` for a local 'const' variable that has an
/// initializer.
class ConstLocalVariableFragmentImpl extends LocalVariableFragmentImpl
    with ConstVariableFragment {
  /// Initialize a newly created local variable element to have the given [name]
  /// and [offset].
  ConstLocalVariableFragmentImpl({
    required super.name2,
    required super.nameOffset,
  });
}

class ConstructorElementImpl extends ExecutableElementImpl
    with
        FragmentedExecutableElementMixin<ConstructorFragmentImpl>,
        FragmentedFunctionTypedElementMixin<ConstructorFragmentImpl>,
        FragmentedTypeParameterizedElementMixin<ConstructorFragmentImpl>,
        FragmentedAnnotatableElementMixin<ConstructorFragmentImpl>,
        FragmentedElementMixin<ConstructorFragmentImpl>,
        ConstructorElementMixin2,
        _HasSinceSdkVersionMixin
    implements ConstructorElement {
  @override
  final Reference reference;

  @override
  final String? name3;

  @override
  final ConstructorFragmentImpl firstFragment;

  ConstructorElementImpl({
    required this.name3,
    required this.reference,
    required this.firstFragment,
  }) {
    reference.element = this;
    firstFragment.element = this;
  }

  @override
  ConstructorElementImpl get baseElement => this;

  /// The constant initializers for this element, from all fragments.
  List<ConstructorInitializer> get constantInitializers {
    return fragments
        .expand((fragment) => fragment.constantInitializers)
        .toList(growable: false);
  }

  @override
  String get displayName {
    var className = enclosingElement.name3 ?? '<null>';
    var name = name3 ?? '<null>';
    if (name != 'new') {
      return '$className.$name';
    } else {
      return className;
    }
  }

  @override
  InterfaceElementImpl get enclosingElement =>
      firstFragment.enclosingElement3.element;

  @Deprecated('Use enclosingElement instead')
  @override
  InterfaceElementImpl get enclosingElement2 => enclosingElement;

  @override
  List<FormalParameterElementMixin> get formalParameters {
    _ensureReadResolution();
    return super.formalParameters;
  }

  @override
  List<ConstructorFragmentImpl> get fragments {
    return [
      for (
        ConstructorFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  bool get isConst => firstFragment.isConst;

  @override
  bool get isDefaultConstructor => firstFragment.isDefaultConstructor;

  @override
  bool get isFactory => firstFragment.isFactory;

  @override
  bool get isGenerative => firstFragment.isGenerative;

  @override
  ElementKind get kind => ElementKind.CONSTRUCTOR;

  @override
  ConstructorFragmentImpl get lastFragment {
    return super.lastFragment as ConstructorFragmentImpl;
  }

  @override
  Element get nonSynthetic {
    if (isSynthetic) {
      return enclosingElement;
    } else {
      return this;
    }
  }

  @override
  ConstructorElementMixin2? get redirectedConstructor2 {
    return firstFragment.redirectedConstructor?.asElement2;
  }

  set redirectedConstructor2(ConstructorElementMixin2? value) {
    firstFragment.redirectedConstructor = value?.asElement;
  }

  @override
  InterfaceTypeImpl get returnType {
    return firstFragment.returnType;
  }

  @override
  ConstructorElementMixin2? get superConstructor2 =>
      firstFragment.superConstructor?.declaration.element;

  set superConstructor2(ConstructorElementMixin2? value) {
    firstFragment.superConstructor = value?.asElement;
  }

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitConstructorElement(this);
  }

  /// Ensures that dependencies of this constructor, such as default values
  /// of formal parameters, are evaluated.
  void computeConstantDependencies() {
    firstFragment.computeConstantDependencies();
  }

  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {
    for (var child in children2) {
      child.accept2(visitor);
    }
  }
}

mixin ConstructorElementMixin
    implements ConstantEvaluationTarget, ExecutableElementOrMember {
  @override
  ConstructorFragmentImpl get declaration;

  /// Whether the constructor is a const constructor.
  bool get isConst;

  /// Whether the constructor can be used as a default constructor - unnamed,
  /// and has no required parameters.
  bool get isDefaultConstructor;

  /// Whether the constructor represents a factory constructor.
  bool get isFactory;

  /// Whether the constructor represents a generative constructor.
  bool get isGenerative;

  @override
  LibraryElementImpl get library2;

  ConstructorElementMixin? get redirectedConstructor;

  @override
  InterfaceTypeImpl get returnType;
}

/// Common implementation for methods defined in [ConstructorElement].
mixin ConstructorElementMixin2
    implements ExecutableElement2OrMember, ConstructorElement {
  @override
  ConstructorElementImpl get baseElement;

  @override
  InterfaceElementImpl get enclosingElement;

  @override
  InterfaceTypeImpl get returnType;
}

/// A concrete implementation of a [ConstructorFragment].
class ConstructorFragmentImpl extends ExecutableFragmentImpl
    with ConstructorElementMixin
    implements ConstructorFragment {
  late final ConstructorElementImpl element;

  /// The super-constructor which this constructor is invoking, or `null` if
  /// this constructor is not generative, or is redirecting, or the
  /// super-constructor is not resolved, or the enclosing class is `Object`.
  ///
  // TODO(scheglov): We cannot have both super and redirecting constructors.
  // So, ideally we should have some kind of "either" or "variant" here.
  ConstructorElementMixin? _superConstructor;

  /// The constructor to which this constructor is redirecting.
  ConstructorElementMixin? _redirectedConstructor;

  /// The initializers for this constructor (used for evaluating constant
  /// instance creation expressions).
  List<ConstructorInitializer> _constantInitializers = const [];

  @override
  String? typeName;

  @override
  int? typeNameOffset;

  @override
  int? periodOffset;

  int? nameEnd;

  @override
  final String name2;

  @override
  int? nameOffset2;

  @override
  ConstructorFragmentImpl? previousFragment;

  @override
  ConstructorFragmentImpl? nextFragment;

  /// For every constructor we initially set this flag to `true`, and then
  /// set it to `false` during computing constant values if we detect that it
  /// is a part of a cycle.
  bool isCycleFree = true;

  @override
  bool isConstantEvaluated = false;

  /// Initialize a newly created constructor element to have the given [name]
  /// and [offset].
  ConstructorFragmentImpl({required this.name2, required super.nameOffset});

  /// Return the constant initializers for this element, which will be empty if
  /// there are no initializers, or `null` if there was an error in the source.
  List<ConstructorInitializer> get constantInitializers {
    _ensureReadResolution();
    return _constantInitializers;
  }

  set constantInitializers(List<ConstructorInitializer> constantInitializers) {
    _constantInitializers = constantInitializers;
  }

  @override
  ConstructorFragmentImpl get declaration => this;

  @override
  String get displayName {
    var className = enclosingElement3.name2;
    var name2 = this.name2;
    if (name2 != 'new') {
      return '$className.$name2';
    } else {
      return className ?? '<null>';
    }
  }

  @override
  InterfaceFragmentImpl get enclosingElement3 =>
      super.enclosingElement3 as InterfaceFragmentImpl;

  @override
  InstanceFragment? get enclosingFragment =>
      enclosingElement3 as InstanceFragment;

  @override
  bool get isConst {
    return hasModifier(Modifier.CONST);
  }

  /// Set whether this constructor represents a 'const' constructor.
  set isConst(bool isConst) {
    setModifier(Modifier.CONST, isConst);
  }

  @override
  bool get isDefaultConstructor {
    // unnamed
    if (name2 != 'new') {
      return false;
    }
    // no required parameters
    for (var parameter in parameters) {
      if (parameter.isRequired) {
        return false;
      }
    }
    // OK, can be used as default constructor
    return true;
  }

  @override
  bool get isFactory {
    return hasModifier(Modifier.FACTORY);
  }

  /// Set whether this constructor represents a factory method.
  set isFactory(bool isFactory) {
    setModifier(Modifier.FACTORY, isFactory);
  }

  @override
  bool get isGenerative {
    return !isFactory;
  }

  @override
  ElementKind get kind => ElementKind.CONSTRUCTOR;

  @override
  LibraryElementImpl get library2 => library;

  @override
  int get nameLength {
    var nameEnd = this.nameEnd;
    if (nameEnd == null) {
      return 0;
    } else {
      return nameEnd - nameOffset;
    }
  }

  @override
  FragmentImpl get nonSynthetic {
    return isSynthetic ? enclosingElement3 : this;
  }

  @override
  int get offset => isSynthetic ? enclosingElement3.offset : _nameOffset;

  @override
  ConstructorElementMixin? get redirectedConstructor {
    _ensureReadResolution();
    return _redirectedConstructor;
  }

  set redirectedConstructor(ConstructorElementMixin? redirectedConstructor) {
    _redirectedConstructor = redirectedConstructor;
  }

  @override
  InterfaceTypeImpl get returnType {
    var result = _returnType;
    if (result != null) {
      return result as InterfaceTypeImpl;
    }

    result = enclosingElement3.element.thisType;
    return _returnType = result as InterfaceTypeImpl;
  }

  ConstructorElementMixin? get superConstructor {
    _ensureReadResolution();
    return _superConstructor;
  }

  set superConstructor(ConstructorElementMixin? superConstructor) {
    _superConstructor = superConstructor;
  }

  @override
  FunctionTypeImpl get type {
    // TODO(scheglov): Remove "element" in the breaking changes branch.
    return _type ??= FunctionTypeImpl(
      typeFormals: typeParameters,
      parameters: parameters.map((f) => f.asElement2).toList(),
      returnType: returnType,
      nullabilitySuffix: NullabilitySuffix.none,
    );
  }

  @override
  set type(FunctionType type) {
    assert(false);
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeConstructorElement(this);
  }

  /// Ensures that dependencies of this constructor, such as default values
  /// of formal parameters, are evaluated.
  void computeConstantDependencies() {
    if (!isConstantEvaluated) {
      computeConstants(
        declaredVariables: context.declaredVariables,
        constants: [this],
        featureSet: library.featureSet,
        configuration: ConstantEvaluationConfiguration(),
      );
    }
  }
}

/// Mixin used by elements that represent constant variables and have
/// initializers.
///
/// Note that in correct Dart code, all constant variables must have
/// initializers.  However, analyzer also needs to handle incorrect Dart code,
/// in which case there might be some constant variables that lack initializers.
/// This interface is only used for constant variables that have initializers.
///
/// This class is not intended to be part of the public API for analyzer.
mixin ConstVariableFragment implements FragmentImpl, ConstantEvaluationTarget {
  /// If this element represents a constant variable, and it has an initializer,
  /// a copy of the initializer for the constant.  Otherwise `null`.
  ///
  /// Note that in correct Dart code, all constant variables must have
  /// initializers.  However, analyzer also needs to handle incorrect Dart code,
  /// in which case there might be some constant variables that lack
  /// initializers.
  ExpressionImpl? constantInitializer;

  Constant? _evaluationResult;

  Constant? get evaluationResult => _evaluationResult;

  set evaluationResult(Constant? evaluationResult) {
    _evaluationResult = evaluationResult;
  }

  @override
  bool get isConstantEvaluated => _evaluationResult != null;

  /// Return a representation of the value of this variable, forcing the value
  /// to be computed if it had not previously been computed, or `null` if either
  /// this variable was not declared with the 'const' modifier or if the value
  /// of this variable could not be computed because of errors.
  DartObject? computeConstantValue() {
    if (evaluationResult == null) {
      var library = this.library;
      // TODO(scheglov): https://github.com/dart-lang/sdk/issues/47915
      if (library == null) {
        throw StateError(
          '[library: null][this: ($runtimeType) $this]'
          '[enclosingElement: $enclosingElement3]',
        );
      }
      computeConstants(
        declaredVariables: context.declaredVariables,
        constants: [this],
        featureSet: library.featureSet,
        configuration: ConstantEvaluationConfiguration(),
      );
    }

    if (evaluationResult case DartObjectImpl result) {
      return result;
    }
    return null;
  }
}

/// A [FieldFormalParameterFragmentImpl] for parameters that have an initializer.
class DefaultFieldFormalParameterElementImpl
    extends FieldFormalParameterFragmentImpl
    with ConstVariableFragment {
  /// Initialize a newly created parameter element to have the given [name] and
  /// [nameOffset].
  DefaultFieldFormalParameterElementImpl({
    required super.nameOffset,
    required super.name2,
    required super.nameOffset2,
    required super.parameterKind,
  });

  @override
  String? get defaultValueCode {
    return constantInitializer?.toSource();
  }
}

/// A [FormalParameterFragmentImpl] for parameters that have an initializer.
class DefaultParameterFragmentImpl extends FormalParameterFragmentImpl
    with ConstVariableFragment {
  /// Initialize a newly created parameter element to have the given [name] and
  /// [nameOffset].
  DefaultParameterFragmentImpl({
    required super.nameOffset,
    required super.name2,
    required super.nameOffset2,
    required super.parameterKind,
  });

  @override
  String? get defaultValueCode {
    return constantInitializer?.toSource();
  }
}

class DefaultSuperFormalParameterElementImpl
    extends SuperFormalParameterFragmentImpl
    with ConstVariableFragment {
  /// Initialize a newly created parameter element to have the given [name] and
  /// [nameOffset].
  DefaultSuperFormalParameterElementImpl({
    required super.nameOffset,
    required super.name2,
    required super.nameOffset2,
    required super.parameterKind,
  });

  @override
  String? get defaultValueCode {
    if (isRequired) {
      return null;
    }

    var constantInitializer = this.constantInitializer;
    if (constantInitializer != null) {
      return constantInitializer.toSource();
    }

    if (_superConstructorParameterDefaultValue != null) {
      return superConstructorParameter?.defaultValueCode;
    }

    return null;
  }

  @override
  Constant? get evaluationResult {
    if (constantInitializer != null) {
      return super.evaluationResult;
    }

    var superConstructorParameter = this.superConstructorParameter?.declaration;
    if (superConstructorParameter is FormalParameterFragmentImpl) {
      return superConstructorParameter.evaluationResult;
    }

    return null;
  }

  DartObject? get _superConstructorParameterDefaultValue {
    var superDefault = superConstructorParameter?.computeConstantValue();
    if (superDefault == null) {
      return null;
    }

    // TODO(scheglov): eliminate this cast
    superDefault as DartObjectImpl;
    var superDefaultType = superDefault.type;

    var typeSystem = library?.typeSystem;
    if (typeSystem == null) {
      return null;
    }

    var requiredType = type.extensionTypeErasure;
    if (typeSystem.isSubtypeOf(superDefaultType, requiredType)) {
      return superDefault;
    }

    return null;
  }

  @override
  DartObject? computeConstantValue() {
    if (constantInitializer != null) {
      return super.computeConstantValue();
    }

    return _superConstructorParameterDefaultValue;
  }
}

/// This mixin is used to set up loading class members from summaries only when
/// they are requested. The summary reader uses [deferReadMembers], and
/// getters invoke [ensureReadMembers].
///
/// We defer reading of both class elements, and class fragments. However
/// getters on class fragments ensure that the whole class element members are
/// read. The reason is that we want to have `nextFragment`, `previousFragment`,
/// and `element` properties return correct value, and reading the whole
/// element is the simplest way to do this.
mixin DeferredMembersReadingMixin {
  void Function()? _readMembersCallback;

  void deferReadMembers(void Function()? callback) {
    assert(_readMembersCallback == null);
    _readMembersCallback = callback;
  }

  void ensureReadMembers() {
    if (_readMembersCallback case var callback?) {
      _readMembersCallback = null;
      callback();
    }
  }
}

/// This mixin is used to set up loading resolution information from summaries
/// on demand, and after all elements are loaded, so for example types can
/// reference them. The summary reader uses [deferReadResolution], and getters
/// invoke [_ensureReadResolution].
mixin DeferredResolutionReadingMixin {
  // TODO(scheglov): review whether we need this
  int _lockResolutionLoading = 0;
  void Function()? _readResolutionCallback;
  ApplyConstantOffsets? applyConstantOffsets;

  void deferReadResolution(void Function()? callback) {
    assert(_readResolutionCallback == null);
    _readResolutionCallback = callback;
  }

  void withoutLoadingResolution(void Function() operation) {
    _lockResolutionLoading++;
    operation();
    _lockResolutionLoading--;
  }

  void _ensureReadResolution() {
    if (_lockResolutionLoading > 0) {
      return;
    }

    if (_readResolutionCallback case var callback?) {
      _readResolutionCallback = null;
      callback();

      // The callback read all AST nodes, apply offsets.
      applyConstantOffsets?.perform();
      applyConstantOffsets = null;
    }
  }
}

class DirectiveUriImpl implements DirectiveUri {}

class DirectiveUriWithLibraryImpl extends DirectiveUriWithSourceImpl
    implements DirectiveUriWithLibrary {
  @override
  late LibraryElementImpl library2;

  DirectiveUriWithLibraryImpl({
    required super.relativeUriString,
    required super.relativeUri,
    required super.source,
    required this.library2,
  });

  DirectiveUriWithLibraryImpl.read({
    required super.relativeUriString,
    required super.relativeUri,
    required super.source,
  });
}

class DirectiveUriWithRelativeUriImpl
    extends DirectiveUriWithRelativeUriStringImpl
    implements DirectiveUriWithRelativeUri {
  @override
  final Uri relativeUri;

  DirectiveUriWithRelativeUriImpl({
    required super.relativeUriString,
    required this.relativeUri,
  });
}

class DirectiveUriWithRelativeUriStringImpl extends DirectiveUriImpl
    implements DirectiveUriWithRelativeUriString {
  @override
  final String relativeUriString;

  DirectiveUriWithRelativeUriStringImpl({required this.relativeUriString});
}

class DirectiveUriWithSourceImpl extends DirectiveUriWithRelativeUriImpl
    implements DirectiveUriWithSource {
  @override
  final Source source;

  DirectiveUriWithSourceImpl({
    required super.relativeUriString,
    required super.relativeUri,
    required this.source,
  });
}

class DirectiveUriWithUnitImpl extends DirectiveUriWithRelativeUriImpl
    implements DirectiveUriWithUnit {
  @override
  final LibraryFragmentImpl libraryFragment;

  DirectiveUriWithUnitImpl({
    required super.relativeUriString,
    required super.relativeUri,
    required this.libraryFragment,
  });

  @override
  Source get source => libraryFragment.source;
}

/// The synthetic element representing the declaration of the type `dynamic`.
class DynamicElementImpl extends TypeDefiningElementImpl {
  /// The unique instance of this class.
  static final DynamicElementImpl instance = DynamicElementImpl._();

  DynamicElementImpl._();

  @override
  Null get documentationComment => null;

  @override
  Element? get enclosingElement => null;

  @Deprecated('Use enclosingElement instead')
  @override
  Element? get enclosingElement2 => enclosingElement;

  @override
  DynamicFragmentImpl get firstFragment => DynamicFragmentImpl.instance;

  @override
  List<DynamicFragmentImpl> get fragments {
    return [
      for (
        DynamicFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  bool get isSynthetic => true;

  @override
  ElementKind get kind => ElementKind.DYNAMIC;

  @override
  Null get library2 => null;

  @override
  MetadataImpl get metadata {
    return MetadataImpl(const []);
  }

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  String get name3 => 'dynamic';

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return null;
  }
}

/// The synthetic element representing the declaration of the type `dynamic`.
class DynamicFragmentImpl extends FragmentImpl implements TypeDefiningFragment {
  /// The unique instance of this class.
  static final DynamicFragmentImpl instance = DynamicFragmentImpl._();

  @override
  final MetadataImpl metadata = MetadataImpl(const []);

  /// Initialize a newly created instance of this class. Instances of this class
  /// should <b>not</b> be created except as part of creating the type
  /// associated with this element. The single instance of this class should be
  /// accessed through the method [instance].
  DynamicFragmentImpl._() : super(nameOffset: -1) {
    setModifier(Modifier.SYNTHETIC, true);
  }

  @override
  List<Fragment> get children3 => const [];

  @override
  DynamicElementImpl get element => DynamicElementImpl.instance;

  @override
  Null get enclosingFragment => null;

  @override
  ElementKind get kind => ElementKind.DYNAMIC;

  @override
  Null get library => null;

  @override
  Null get libraryFragment => null;

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  String get name2 => 'dynamic';

  @override
  Null get nameOffset2 => null;

  @override
  Null get nextFragment => null;

  @override
  int get offset => 0;

  @override
  Null get previousFragment => null;
}

/// A concrete implementation of an [ElementAnnotation].
class ElementAnnotationImpl implements ElementAnnotation {
  /// The name of the top-level variable used to mark that a function always
  /// throws, for dead code purposes.
  static const String _alwaysThrowsVariableName = 'alwaysThrows';

  /// The name of the top-level variable used to mark an element as not needing
  /// to be awaited.
  static const String _awaitNotRequiredVariableName = 'awaitNotRequired';

  /// The name of the class used to mark an element as being deprecated.
  static const String _deprecatedClassName = 'Deprecated';

  /// The name of the top-level variable used to mark an element as being
  /// deprecated.
  static const String _deprecatedVariableName = 'deprecated';

  /// The name of the top-level variable used to mark an element as not to be
  /// stored.
  static const String _doNotStoreVariableName = 'doNotStore';

  /// The name of the top-level variable used to mark a declaration as not to be
  /// used (for ephemeral testing and debugging only).
  static const String _doNotSubmitVariableName = 'doNotSubmit';

  /// The name of the top-level variable used to mark a declaration as experimental.
  static const String _experimentalVariableName = 'experimental';

  /// The name of the top-level variable used to mark a method as being a
  /// factory.
  static const String _factoryVariableName = 'factory';

  /// The name of the top-level variable used to mark a class and its subclasses
  /// as being immutable.
  static const String _immutableVariableName = 'immutable';

  /// The name of the top-level variable used to mark an element as being
  /// internal to its package.
  static const String _internalVariableName = 'internal';

  /// The name of the top-level variable used to mark a constructor as being
  /// literal.
  static const String _literalVariableName = 'literal';

  /// The name of the top-level variable used to mark a returned element as
  /// requiring use.
  static const String _mustBeConstVariableName = 'mustBeConst';

  /// The name of the top-level variable used to mark a type as having
  /// "optional" type arguments.
  static const String _optionalTypeArgsVariableName = 'optionalTypeArgs';

  /// The name of the top-level variable used to mark a function as running
  /// a single test.
  static const String _isTestVariableName = 'isTest';

  /// The name of the top-level variable used to mark a function as a Flutter
  /// widget factory.
  static const String _widgetFactoryName = 'widgetFactory';

  /// The URI of the Flutter widget inspector library.
  static final Uri _flutterWidgetInspectorLibraryUri = Uri.parse(
    'package:flutter/src/widgets/widget_inspector.dart',
  );

  /// The name of the top-level variable used to mark a function as running
  /// a test group.
  static const String _isTestGroupVariableName = 'isTestGroup';

  /// The name of the class used to JS annotate an element.
  static const String _jsClassName = 'JS';

  /// The name of `_js_annotations` library, used to define JS annotations.
  static const String _jsLibName = '_js_annotations';

  /// The name of `meta` library, used to define analysis annotations.
  static const String _metaLibName = 'meta';

  /// The name of `meta_meta` library, used to define annotations for other
  /// annotations.
  static const String _metaMetaLibName = 'meta_meta';

  /// The name of the top-level variable used to mark a method as requiring
  /// subclasses to override this method.
  static const String _mustBeOverridden = 'mustBeOverridden';

  /// The name of the top-level variable used to mark a method as requiring
  /// overriders to call super.
  static const String _mustCallSuperVariableName = 'mustCallSuper';

  /// The name of `angular.meta` library, used to define angular analysis
  /// annotations.
  static const String _angularMetaLibName = 'angular.meta';

  /// The name of the top-level variable used to mark a member as being nonVirtual.
  static const String _nonVirtualVariableName = 'nonVirtual';

  /// The name of the top-level variable used to mark a method as being expected
  /// to override an inherited method.
  static const String _overrideVariableName = 'override';

  /// The name of the top-level variable used to mark a method as being
  /// protected.
  static const String _protectedVariableName = 'protected';

  /// The name of the top-level variable used to mark a member as redeclaring.
  static const String _redeclareVariableName = 'redeclare';

  /// The name of the top-level variable used to mark a class or mixin as being
  /// reopened.
  static const String _reopenVariableName = 'reopen';

  /// The name of the class used to mark a parameter as being required.
  static const String _requiredClassName = 'Required';

  /// The name of the top-level variable used to mark a parameter as being
  /// required.
  static const String _requiredVariableName = 'required';

  /// The name of the top-level variable used to mark a class as being sealed.
  static const String _sealedVariableName = 'sealed';

  /// The name of the class used to annotate a class as an annotation with a
  /// specific set of target element kinds.
  static const String _targetClassName = 'Target';

  /// The name of the class used to mark a returned element as requiring use.
  static const String _useResultClassName = 'UseResult';

  /// The name of the top-level variable used to mark a returned element as
  /// requiring use.
  static const String _useResultVariableName = 'useResult';

  /// The name of the top-level variable used to mark a member as being visible
  /// for overriding only.
  static const String _visibleForOverridingName = 'visibleForOverriding';

  /// The name of the top-level variable used to mark a method as being
  /// visible for templates.
  static const String _visibleForTemplateVariableName = 'visibleForTemplate';

  /// The name of the top-level variable used to mark a method as being
  /// visible for testing.
  static const String _visibleForTestingVariableName = 'visibleForTesting';

  /// The name of the top-level variable used to mark a method as being
  /// visible outside of template files.
  static const String _visibleOutsideTemplateVariableName =
      'visibleOutsideTemplate';

  @override
  Element? element2;

  /// The compilation unit in which this annotation appears.
  LibraryFragmentImpl compilationUnit;

  /// The AST of the annotation itself, cloned from the resolved AST for the
  /// source code.
  late AnnotationImpl annotationAst;

  /// The result of evaluating this annotation as a compile-time constant
  /// expression, or `null` if the compilation unit containing the variable has
  /// not been resolved.
  Constant? evaluationResult;

  /// Any additional errors, other than [evaluationResult] being an
  /// [InvalidConstant], that came from evaluating the constant expression,
  /// or `null` if the compilation unit containing the variable has
  /// not been resolved.
  ///
  // TODO(kallentu): Remove this field once we fix up g3's dependency on
  // annotations having a valid result as well as unresolved errors.
  List<Diagnostic>? additionalErrors;

  /// Initialize a newly created annotation. The given [compilationUnit] is the
  /// compilation unit in which the annotation appears.
  ElementAnnotationImpl(this.compilationUnit);

  @override
  List<Diagnostic> get constantEvaluationErrors {
    var evaluationResult = this.evaluationResult;
    var additionalErrors = this.additionalErrors;
    if (evaluationResult is InvalidConstant) {
      // When we have an [InvalidConstant], we don't report the additional
      // errors because this result contains the most relevant error.
      return [
        Diagnostic.tmp(
          source: source,
          offset: evaluationResult.offset,
          length: evaluationResult.length,
          diagnosticCode: evaluationResult.diagnosticCode,
          arguments: evaluationResult.arguments,
          contextMessages: evaluationResult.contextMessages,
        ),
      ];
    }
    return additionalErrors ?? const <Diagnostic>[];
  }

  @override
  AnalysisContext get context => compilationUnit.library.context;

  @override
  bool get isAlwaysThrows => _isPackageMetaGetter(_alwaysThrowsVariableName);

  @override
  bool get isAwaitNotRequired =>
      _isPackageMetaGetter(_awaitNotRequiredVariableName);

  @override
  bool get isConstantEvaluated => evaluationResult != null;

  bool get isDartInternalSince {
    var element2 = this.element2;
    if (element2 is ConstructorElement) {
      return element2.enclosingElement.name3 == 'Since' &&
          element2.library2.uri.toString() == 'dart:_internal';
    }
    return false;
  }

  @override
  bool get isDeprecated {
    var element2 = this.element2;
    if (element2 is ConstructorElement) {
      return element2.library2.isDartCore &&
          element2.enclosingElement.name3 == _deprecatedClassName;
    } else if (element2 is PropertyAccessorElement) {
      return element2.library2.isDartCore &&
          element2.name3 == _deprecatedVariableName;
    }
    return false;
  }

  @override
  bool get isDoNotStore => _isPackageMetaGetter(_doNotStoreVariableName);

  @override
  bool get isDoNotSubmit => _isPackageMetaGetter(_doNotSubmitVariableName);

  @override
  bool get isExperimental => _isPackageMetaGetter(_experimentalVariableName);

  @override
  bool get isFactory => _isPackageMetaGetter(_factoryVariableName);

  @override
  bool get isImmutable => _isPackageMetaGetter(_immutableVariableName);

  @override
  bool get isInternal => _isPackageMetaGetter(_internalVariableName);

  @override
  bool get isIsTest => _isPackageMetaGetter(_isTestVariableName);

  @override
  bool get isIsTestGroup => _isPackageMetaGetter(_isTestGroupVariableName);

  @override
  bool get isJS =>
      _isConstructor(libraryName: _jsLibName, className: _jsClassName);

  @override
  bool get isLiteral => _isPackageMetaGetter(_literalVariableName);

  @override
  bool get isMustBeConst => _isPackageMetaGetter(_mustBeConstVariableName);

  @override
  bool get isMustBeOverridden => _isPackageMetaGetter(_mustBeOverridden);

  @override
  bool get isMustCallSuper => _isPackageMetaGetter(_mustCallSuperVariableName);

  @override
  bool get isNonVirtual => _isPackageMetaGetter(_nonVirtualVariableName);

  @override
  bool get isOptionalTypeArgs =>
      _isPackageMetaGetter(_optionalTypeArgsVariableName);

  @override
  bool get isOverride => _isDartCoreGetter(_overrideVariableName);

  /// Return `true` if this is an annotation of the form
  /// `@pragma("vm:entry-point")`.
  bool get isPragmaVmEntryPoint {
    if (_isConstructor(libraryName: 'dart.core', className: 'pragma')) {
      var value = computeConstantValue();
      var nameValue = value?.getField('name');
      return nameValue?.toStringValue() == 'vm:entry-point';
    }
    return false;
  }

  @override
  bool get isProtected => _isPackageMetaGetter(_protectedVariableName);

  @override
  bool get isProxy => false;

  @override
  bool get isRedeclare => _isPackageMetaGetter(_redeclareVariableName);

  @override
  bool get isReopen => _isPackageMetaGetter(_reopenVariableName);

  @override
  bool get isRequired =>
      _isConstructor(
        libraryName: _metaLibName,
        className: _requiredClassName,
      ) ||
      _isPackageMetaGetter(_requiredVariableName);

  @override
  bool get isSealed => _isPackageMetaGetter(_sealedVariableName);

  @override
  bool get isTarget => _isConstructor(
    libraryName: _metaMetaLibName,
    className: _targetClassName,
  );

  @override
  bool get isUseResult =>
      _isConstructor(
        libraryName: _metaLibName,
        className: _useResultClassName,
      ) ||
      _isPackageMetaGetter(_useResultVariableName);

  @override
  bool get isVisibleForOverriding =>
      _isPackageMetaGetter(_visibleForOverridingName);

  @override
  bool get isVisibleForTemplate => _isTopGetter(
    libraryName: _angularMetaLibName,
    name: _visibleForTemplateVariableName,
  );

  @override
  bool get isVisibleForTesting =>
      _isPackageMetaGetter(_visibleForTestingVariableName);

  @override
  bool get isVisibleOutsideTemplate => _isTopGetter(
    libraryName: _angularMetaLibName,
    name: _visibleOutsideTemplateVariableName,
  );

  @override
  bool get isWidgetFactory => _isTopGetter(
    libraryUri: _flutterWidgetInspectorLibraryUri,
    name: _widgetFactoryName,
  );

  @override
  LibraryElementImpl get library2 => compilationUnit.library;

  @override
  Source get librarySource => compilationUnit.librarySource;

  @override
  Source get source => compilationUnit.source;

  @override
  DartObject? computeConstantValue() {
    if (evaluationResult == null) {
      computeConstants(
        declaredVariables: context.declaredVariables,
        constants: [this],
        featureSet: compilationUnit.library.featureSet,
        configuration: ConstantEvaluationConfiguration(),
      );
    }

    if (evaluationResult case DartObjectImpl result) {
      return result;
    }
    return null;
  }

  @override
  String toSource() => annotationAst.toSource();

  @override
  String toString() => '@$element2';

  bool _isConstructor({
    required String libraryName,
    required String className,
  }) {
    var element2 = this.element2;
    return element2 is ConstructorElement &&
        element2.enclosingElement.name3 == className &&
        element2.library2.name3 == libraryName;
  }

  bool _isDartCoreGetter(String name) {
    return _isTopGetter(libraryName: 'dart.core', name: name);
  }

  bool _isPackageMetaGetter(String name) {
    return _isTopGetter(libraryName: _metaLibName, name: name);
  }

  bool _isTopGetter({
    String? libraryName,
    Uri? libraryUri,
    required String name,
  }) {
    assert(
      (libraryName != null) != (libraryUri != null),
      'Exactly one of libraryName/libraryUri should be provided',
    );
    var element2 = this.element2;
    return element2 is PropertyAccessorElement &&
        element2.name3 == name &&
        (libraryName == null || element2.library2.name3 == libraryName) &&
        (libraryUri == null || element2.library2.uri == libraryUri);
  }
}

sealed class ElementDirectiveImpl implements ElementDirective {
  @override
  late LibraryFragmentImpl libraryFragment;

  @override
  final DirectiveUri uri;

  @override
  MetadataImpl metadata = MetadataImpl(const []);

  ElementDirectiveImpl({required this.uri});

  @override
  Null get documentationComment => null;

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;
}

abstract class ElementImpl implements Element {
  @override
  final int id = FragmentImpl._NEXT_ID++;

  /// The modifiers associated with this element.
  EnumSet<Modifier> _modifiers = EnumSet.empty();

  @override
  Element get baseElement => this;

  @override
  List<Element> get children2 => const [];

  @override
  String get displayName => name3 ?? '<unnamed>';

  @override
  List<Fragment> get fragments {
    return [
      for (
        Fragment? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  /// Return an identifier that uniquely identifies this element among the
  /// children of this element's parent.
  String get identifier {
    var identifier = name3!;
    // TODO(augmentations): Figure out how to get a unique identifier. In the
    //  old model we sometimes used the offset of the name to disambiguate
    //  between elements, but we can't do that anymore because the name can
    //  appear at multiple offsets.
    return considerCanonicalizeString(identifier);
  }

  @override
  bool get isPrivate {
    var name3 = this.name3;
    if (name3 == null) {
      return true;
    }
    return Identifier.isPrivateName(name3);
  }

  @override
  bool get isPublic => !isPrivate;

  @override
  String? get lookupName {
    return name3;
  }

  @override
  Element get nonSynthetic => this;

  @Deprecated('Use nonSynthetic instead')
  @override
  Element get nonSynthetic2 => nonSynthetic;

  /// The reference of this element, used during reading summaries.
  ///
  /// Can be `null` if this element cannot be referenced from outside,
  /// for example a [LocalFunctionElement], a [TypeParameterElement],
  /// a positional [FormalParameterElement], etc.
  Reference? get reference => null;

  @override
  AnalysisSession? get session {
    return enclosingElement?.session;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other);
  }

  /// Append a textual representation of this element to the given [builder].
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeAbstractElement2(this);
  }

  @override
  String displayString2({
    bool multiline = false,
    bool preferTypeAlias = false,
  }) {
    var builder = ElementDisplayStringBuilder(
      multiline: multiline,
      preferTypeAlias: preferTypeAlias,
    );
    appendTo(builder);
    return builder.toString();
  }

  @override
  String getExtendedDisplayName2({String? shortName}) {
    shortName ??= displayName;
    var source = firstFragment.libraryFragment?.source;
    return "$shortName (${source?.fullName})";
  }

  /// Whether this element has the [modifier].
  bool hasModifier(Modifier modifier) => _modifiers[modifier];

  @override
  bool isAccessibleIn2(LibraryElement library) {
    var name3 = this.name3;
    if (name3 == null || Identifier.isPrivateName(name3)) {
      return library == library2;
    }
    return true;
  }

  /// Update [modifier] of this element to [value].
  void setModifier(Modifier modifier, bool value) {
    _modifiers = _modifiers.updated(modifier, value);
  }

  @override
  Element? thisOrAncestorMatching2(bool Function(Element p1) predicate) {
    Element? element = this;
    while (element != null && !predicate(element)) {
      element = element.enclosingElement;
    }
    return element;
  }

  @override
  E? thisOrAncestorOfType2<E extends Element>() {
    Element element = this;
    while (element is! E) {
      var ancestor = element.enclosingElement;
      if (ancestor == null) return null;
      element = ancestor;
    }
    return element;
  }

  @override
  String toString() {
    return displayString2();
  }

  /// Use the given [visitor] to visit all of the children of this element.
  /// There is no guarantee of the order in which the children will be visited.
  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {
    for (var child in children2) {
      child.accept2(visitor);
    }
  }
}

class EnumElementImpl extends InterfaceElementImpl implements EnumElement {
  @override
  final Reference reference;

  @override
  final EnumFragmentImpl firstFragment;

  EnumElementImpl(this.reference, this.firstFragment) {
    reference.element = this;
    firstFragment.augmentedInternal = this;
  }

  @override
  List<FieldElementImpl> get constants2 {
    return fields.where((field) => field.isEnumConstant).toList();
  }

  @override
  List<EnumFragmentImpl> get fragments {
    return [
      for (
        EnumFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitEnumElement(this);
  }
}

/// An [InterfaceFragmentImpl] which is an enum.
class EnumFragmentImpl extends InterfaceFragmentImpl implements EnumFragment {
  late EnumElementImpl augmentedInternal;

  /// Initialize a newly created class element to have the given [name] at the
  /// given [offset] in the file that contains the declaration of this element.
  EnumFragmentImpl({required super.name2, required super.nameOffset});

  List<FieldFragmentImpl> get constants {
    return fields.where((field) => field.isEnumConstant).toList();
  }

  @override
  List<FieldElement> get constants2 =>
      constants.map((e) => e.asElement2).toList();

  @override
  EnumElementImpl get element {
    _ensureReadResolution();
    return augmentedInternal;
  }

  @override
  ElementKind get kind => ElementKind.ENUM;

  @override
  EnumFragmentImpl? get nextFragment => super.nextFragment as EnumFragmentImpl?;

  @override
  EnumFragmentImpl? get previousFragment =>
      super.previousFragment as EnumFragmentImpl?;

  FieldFragmentImpl? get valuesField {
    for (var field in fields) {
      if (field.name2 == 'values' && field.isSyntheticEnumField) {
        return field;
      }
    }
    return null;
  }

  void addFragment(EnumFragmentImpl fragment) {
    fragment.augmentedInternal = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeEnumElement(this);
  }
}

/// Common base class for all analyzer-internal classes that implement
/// `ExecutableElement2`.
abstract class ExecutableElement2OrMember implements ExecutableElement {
  @override
  ExecutableElementImpl get baseElement;

  @override
  List<FormalParameterElementMixin> get formalParameters;

  @override
  MetadataImpl get metadata;

  @override
  TypeImpl get returnType;

  @override
  FunctionTypeImpl get type;
}

abstract class ExecutableElementImpl extends FunctionTypedElementImpl
    with DeferredResolutionReadingMixin
    implements ExecutableElement2OrMember, AnnotatableElementImpl {
  TypeImpl? _returnType;

  @override
  ExecutableElementImpl get baseElement => this;

  @override
  List<Element> get children2 => [
    ...super.children2,
    ...typeParameters2,
    ...formalParameters,
  ];

  /// Whether the type of this element references a type parameter of the
  /// enclosing element. This includes not only explicitly specified type
  /// annotations, but also inferred types.
  ///
  /// Top-level declarations don't have enclosing element type parameters,
  /// so for them this flag is always `false`.
  bool get hasEnclosingTypeParameterReference {
    var firstFragment = this.firstFragment as ExecutableFragmentImpl;
    return firstFragment.hasEnclosingTypeParameterReference;
  }

  bool get invokesSuperSelf {
    var firstFragment = this.firstFragment as ExecutableFragmentImpl;
    return firstFragment.hasModifier(Modifier.INVOKES_SUPER_SELF);
  }

  ExecutableFragmentImpl get lastFragment {
    var result = firstFragment as ExecutableFragmentImpl;
    while (true) {
      if (result.nextFragment case ExecutableFragmentImpl nextFragment) {
        result = nextFragment;
      } else {
        return result;
      }
    }
  }

  @override
  LibraryElement get library2 {
    var firstFragment = this.firstFragment as ExecutableFragmentImpl;
    return firstFragment.library;
  }

  @override
  TypeImpl get returnType {
    _ensureReadResolution();

    // If a synthetic getter, we might need to infer the type.
    if (_returnType == null && isSynthetic) {
      if (this case GetterElementImpl thisGetter) {
        thisGetter.variable3!.type;
      }
    }

    return _returnType!;
  }

  set returnType(TypeImpl value) {
    _returnType = value;
  }
}

/// Common base class for all analyzer-internal classes that implement
/// `ExecutableElement`.
abstract class ExecutableElementOrMember implements FragmentOrMember {
  @override
  ExecutableElementOrMember get declaration;

  @override
  String get displayName;

  /// Whether the executable element did not have an explicit return type
  /// specified for it in the original source.
  bool get hasImplicitReturnType;

  /// Whether the executable element is abstract.
  ///
  /// Executable elements are abstract if they are not external, and have no
  /// body.
  bool get isAbstract;

  /// Whether the executable element has body marked as being asynchronous.
  bool get isAsynchronous;

  /// Whether the element is an augmentation.
  ///
  /// If `true`, declaration has the explicit `augment` modifier.
  bool get isAugmentation;

  /// Whether the executable element is an extension type member.
  bool get isExtensionTypeMember;

  /// Whether the executable element is external.
  ///
  /// Executable elements are external if they are explicitly marked as such
  /// using the 'external' keyword.
  bool get isExternal;

  /// Whether the executable element has a body marked as being a generator.
  bool get isGenerator;

  /// Whether the executable element is an operator.
  ///
  /// The test may be based on the name of the executable element, in which
  /// case the result will be correct when the name is legal.
  bool get isOperator;

  /// Whether the element is a static element.
  ///
  /// A static element is an element that is not associated with a particular
  /// instance, but rather with an entire library or class.
  bool get isStatic;

  /// Whether the executable element has a body marked as being synchronous.
  bool get isSynchronous;

  /// The parameters defined by this executable element.
  List<ParameterElementMixin> get parameters;

  /// The return type defined by this element.
  TypeImpl get returnType;

  @override
  Source get source;

  /// The type defined by this element.
  FunctionTypeImpl get type;

  /// The type parameters declared by this element directly.
  ///
  /// This does not include type parameters that are declared by any enclosing
  /// elements.
  List<TypeParameterFragmentImpl> get typeParameters;
}

abstract class ExecutableFragmentImpl extends _ExistingFragmentImpl
    with
        AugmentableFragment,
        DeferredResolutionReadingMixin,
        TypeParameterizedFragmentMixin
    implements ExecutableElementOrMember, ExecutableFragment {
  /// A list containing all of the parameters defined by this executable
  /// element.
  List<FormalParameterFragmentImpl> _parameters = const [];

  /// The inferred return type of this executable element.
  TypeImpl? _returnType;

  /// The type of function defined by this executable element.
  FunctionTypeImpl? _type;

  /// Initialize a newly created executable element to have the given [name] and
  /// [offset].
  ExecutableFragmentImpl({required super.nameOffset});

  @override
  List<Fragment> get children3 => [...typeParameters, ...parameters];

  @override
  ExecutableFragmentImpl get declaration => this;

  @override
  ExecutableElementImpl get element;

  @override
  FragmentImpl get enclosingElement3 {
    return super.enclosingElement3!;
  }

  @override
  List<FormalParameterFragmentImpl> get formalParameters => parameters;

  /// Whether the type of this fragment references a type parameter of the
  /// enclosing element. This includes not only explicitly specified type
  /// annotations, but also inferred types.
  bool get hasEnclosingTypeParameterReference {
    return !hasModifier(Modifier.NO_ENCLOSING_TYPE_PARAMETER_REFERENCE);
  }

  set hasEnclosingTypeParameterReference(bool value) {
    setModifier(Modifier.NO_ENCLOSING_TYPE_PARAMETER_REFERENCE, !value);
  }

  @override
  bool get hasImplicitReturnType {
    return hasModifier(Modifier.IMPLICIT_TYPE);
  }

  /// Set whether this executable element has an implicit return type.
  set hasImplicitReturnType(bool hasImplicitReturnType) {
    setModifier(Modifier.IMPLICIT_TYPE, hasImplicitReturnType);
  }

  bool get invokesSuperSelf {
    return hasModifier(Modifier.INVOKES_SUPER_SELF);
  }

  set invokesSuperSelf(bool value) {
    setModifier(Modifier.INVOKES_SUPER_SELF, value);
  }

  @override
  bool get isAbstract {
    return hasModifier(Modifier.ABSTRACT);
  }

  @override
  bool get isAsynchronous {
    return hasModifier(Modifier.ASYNCHRONOUS);
  }

  /// Set whether this executable element's body is asynchronous.
  set isAsynchronous(bool isAsynchronous) {
    setModifier(Modifier.ASYNCHRONOUS, isAsynchronous);
  }

  @override
  bool get isExtensionTypeMember {
    return hasModifier(Modifier.EXTENSION_TYPE_MEMBER);
  }

  set isExtensionTypeMember(bool value) {
    setModifier(Modifier.EXTENSION_TYPE_MEMBER, value);
  }

  @override
  bool get isExternal {
    return hasModifier(Modifier.EXTERNAL);
  }

  /// Set whether this executable element is external.
  set isExternal(bool isExternal) {
    setModifier(Modifier.EXTERNAL, isExternal);
  }

  @override
  bool get isGenerator {
    return hasModifier(Modifier.GENERATOR);
  }

  /// Set whether this method's body is a generator.
  set isGenerator(bool isGenerator) {
    setModifier(Modifier.GENERATOR, isGenerator);
  }

  @override
  bool get isOperator => false;

  @override
  bool get isStatic {
    return hasModifier(Modifier.STATIC);
  }

  set isStatic(bool isStatic) {
    setModifier(Modifier.STATIC, isStatic);
  }

  @override
  bool get isSynchronous => !isAsynchronous;

  @override
  MetadataImpl get metadata {
    _ensureReadResolution();
    return super.metadata;
  }

  @override
  int get offset => _nameOffset;

  @override
  List<FormalParameterFragmentImpl> get parameters {
    _ensureReadResolution();
    return _parameters;
  }

  /// Set the parameters defined by this executable element to the given
  /// [parameters].
  set parameters(List<FormalParameterFragmentImpl> parameters) {
    for (var parameter in parameters) {
      parameter.enclosingElement3 = this;
    }
    _parameters = parameters;
  }

  List<FormalParameterFragmentImpl> get parameters_unresolved {
    return _parameters;
  }

  @override
  TypeImpl get returnType {
    _ensureReadResolution();

    // If a synthetic getter, we might need to infer the type.
    if (_returnType == null && isSynthetic) {
      if (this case GetterFragmentImpl thisGetter) {
        thisGetter.element.variable3!.type;
      } else if (this case SetterFragmentImpl thisSetter) {
        thisSetter.element.variable3!.type;
      }
    }

    return _returnType!;
  }

  set returnType(DartType returnType) {
    // TODO(paulberry): eliminate this cast by changing the setter parameter
    // type to `TypeImpl`.
    _returnType = returnType as TypeImpl;
    // We do this because of return type inference. At the moment when we
    // create a local function element we don't know yet its return type,
    // because we have not done static type analysis yet.
    // It somewhere it between we access the type of this element, so it gets
    // cached in the element. When we are done static type analysis, we then
    // should clear this cached type to make it right.
    // TODO(scheglov): Remove when type analysis is done in the single pass.
    _type = null;
  }

  @override
  FunctionTypeImpl get type {
    if (_type != null) return _type!;

    return _type = FunctionTypeImpl(
      typeFormals: typeParameters,
      parameters: parameters.map((f) => f.asElement2).toList(),
      returnType: returnType,
      nullabilitySuffix: NullabilitySuffix.none,
    );
  }

  set type(FunctionTypeImpl type) {
    _type = type;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeExecutableElement(this, displayName);
  }
}

class ExtensionElementImpl extends InstanceElementImpl
    with _HasSinceSdkVersionMixin
    implements ExtensionElement {
  @override
  final Reference reference;

  @override
  final ExtensionFragmentImpl firstFragment;

  TypeImpl _extendedType = InvalidTypeImpl.instance;

  ExtensionElementImpl(this.reference, this.firstFragment) {
    reference.element = this;
    firstFragment.augmentedInternal = this;
  }

  @override
  TypeImpl get extendedType {
    _ensureReadResolution();
    return _extendedType;
  }

  set extendedType(TypeImpl value) {
    _extendedType = value;
  }

  @override
  List<ExtensionFragmentImpl> get fragments {
    return [
      for (
        ExtensionFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  DartType get thisType => extendedType;

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitExtensionElement(this);
  }
}

class ExtensionFragmentImpl extends InstanceFragmentImpl
    implements ExtensionFragment {
  late ExtensionElementImpl augmentedInternal;

  /// Initialize a newly created extension element to have the given [name] at
  /// the given [nameOffset] in the file that contains the declaration of this
  /// element.
  ExtensionFragmentImpl({required super.name2, required super.nameOffset});

  @override
  List<Fragment> get children3 => [
    ...fields,
    ...getters,
    ...methods,
    ...setters,
    ...typeParameters,
  ];

  @override
  String get displayName => name2 ?? '';

  @override
  ExtensionElementImpl get element {
    _ensureReadResolution();
    return augmentedInternal;
  }

  TypeImpl get extendedType {
    return element.extendedType;
  }

  @override
  bool get isPrivate {
    var name = name2;
    return name == null || Identifier.isPrivateName(name);
  }

  @override
  bool get isSimplyBounded => true;

  @override
  ElementKind get kind => ElementKind.EXTENSION;

  @override
  MetadataImpl get metadata {
    _ensureReadResolution();
    return super.metadata;
  }

  @override
  ExtensionFragmentImpl? get nextFragment =>
      super.nextFragment as ExtensionFragmentImpl?;

  @override
  int get offset => nameOffset2 ?? _codeOffset ?? 0;

  @override
  ExtensionFragmentImpl? get previousFragment =>
      super.previousFragment as ExtensionFragmentImpl?;

  void addFragment(ExtensionFragmentImpl fragment) {
    fragment.augmentedInternal = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeExtensionElement(this);
  }
}

class ExtensionTypeElementImpl extends InterfaceElementImpl
    implements ExtensionTypeElement {
  @override
  final Reference reference;

  @override
  final ExtensionTypeFragmentImpl firstFragment;

  ExtensionTypeElementImpl(this.reference, this.firstFragment) {
    reference.element = this;
    firstFragment.augmentedInternal = this;
  }

  @override
  List<ExtensionTypeFragmentImpl> get fragments {
    return [
      for (
        ExtensionTypeFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  /// Whether the element has direct or indirect reference to itself,
  /// in implemented superinterfaces.
  bool get hasImplementsSelfReference {
    return firstFragment.hasImplementsSelfReference;
  }

  /// Whether the element has direct or indirect reference to itself,
  /// in implemented superinterfaces.
  set hasImplementsSelfReference(bool value) {
    firstFragment.hasImplementsSelfReference = value;
  }

  /// Whether the element has direct or indirect reference to itself,
  /// in representation.
  bool get hasRepresentationSelfReference {
    return firstFragment.hasRepresentationSelfReference;
  }

  /// Whether the element has direct or indirect reference to itself,
  /// in representation.
  set hasRepresentationSelfReference(bool value) {
    firstFragment.hasRepresentationSelfReference = value;
  }

  @override
  ConstructorElement get primaryConstructor {
    return firstFragment.primaryConstructor.element;
  }

  @Deprecated('Use primaryConstructor instead')
  @override
  ConstructorElement get primaryConstructor2 {
    return primaryConstructor;
  }

  @override
  FieldElementImpl get representation {
    return firstFragment.representation.element;
  }

  @Deprecated('Use representation instead')
  @override
  FieldElementImpl get representation2 {
    return representation;
  }

  @override
  DartType get typeErasure => firstFragment.typeErasure;

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitExtensionTypeElement(this);
  }
}

class ExtensionTypeFragmentImpl extends InterfaceFragmentImpl
    implements ExtensionTypeFragment {
  late ExtensionTypeElementImpl augmentedInternal;

  late DartType typeErasure;

  /// Whether the element has direct or indirect reference to itself,
  /// in representation.
  bool hasRepresentationSelfReference = false;

  /// Whether the element has direct or indirect reference to itself,
  /// in implemented superinterfaces.
  bool hasImplementsSelfReference = false;

  ExtensionTypeFragmentImpl({required super.name2, required super.nameOffset});

  @override
  ExtensionTypeElementImpl get element {
    _ensureReadResolution();
    return augmentedInternal;
  }

  @override
  ElementKind get kind {
    return ElementKind.EXTENSION_TYPE;
  }

  @override
  ExtensionTypeFragmentImpl? get nextFragment =>
      super.nextFragment as ExtensionTypeFragmentImpl?;

  @override
  ExtensionTypeFragmentImpl? get previousFragment =>
      super.previousFragment as ExtensionTypeFragmentImpl?;

  @override
  ConstructorFragmentImpl get primaryConstructor {
    return constructors.first;
  }

  @Deprecated('Use primaryConstructor instead')
  @override
  ConstructorFragmentImpl get primaryConstructor2 => primaryConstructor;

  @override
  FieldFragmentImpl get representation {
    return fields.first;
  }

  @Deprecated('Use representation instead')
  @override
  FieldFragmentImpl get representation2 => representation;

  void addFragment(ExtensionTypeFragmentImpl fragment) {
    fragment.augmentedInternal = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeExtensionTypeElement(this);
  }
}

/// Common base class for all analyzer-internal classes that implement
/// `FieldElement2`.
abstract class FieldElement2OrMember
    implements PropertyInducingElement2OrMember, FieldElement {}

class FieldElementImpl extends PropertyInducingElementImpl
    with
        FragmentedAnnotatableElementMixin<FieldFragmentImpl>,
        FragmentedElementMixin<FieldFragmentImpl>,
        _HasSinceSdkVersionMixin
    implements FieldElement2OrMember {
  @override
  final Reference reference;

  @override
  final FieldFragmentImpl firstFragment;

  FieldElementImpl({required this.reference, required this.firstFragment}) {
    reference.element = this;
    firstFragment.element = this;
  }

  @override
  FieldElement get baseElement => this;

  @override
  InstanceElement get enclosingElement =>
      (firstFragment.enclosingElement3 as InstanceFragment).element;

  @Deprecated('Use enclosingElement instead')
  @override
  InstanceElement get enclosingElement2 => enclosingElement;

  @override
  List<FieldFragmentImpl> get fragments {
    return [
      for (
        FieldFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  /// Whether the type of this fragment references a type parameter of the
  /// enclosing element. This includes not only explicitly specified type
  /// annotations, but also inferred types.
  bool get hasEnclosingTypeParameterReference {
    return firstFragment.hasEnclosingTypeParameterReference;
  }

  @override
  bool get hasImplicitType => firstFragment.hasImplicitType;

  @override
  bool get isAbstract => firstFragment.isAbstract;

  @override
  bool get isConst => firstFragment.isConst;

  @override
  bool get isCovariant => firstFragment.isCovariant;

  @override
  bool get isEnumConstant => firstFragment.isEnumConstant;

  bool get isEnumValues {
    return enclosingElement is EnumElementImpl && name3 == 'values';
  }

  @override
  bool get isExternal => firstFragment.isExternal;

  @override
  bool get isFinal => firstFragment.isFinal;

  @override
  bool get isLate => firstFragment.isLate;

  @override
  bool get isPromotable => firstFragment.isPromotable;

  @override
  bool get isStatic => firstFragment.isStatic;

  @override
  ElementKind get kind => ElementKind.FIELD;

  @override
  LibraryElementImpl get library2 {
    return firstFragment.library;
  }

  @override
  String? get name3 => firstFragment.name2;

  @override
  TypeImpl get type => firstFragment.type;

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitFieldElement(this);
  }

  @override
  DartObject? computeConstantValue() => firstFragment.computeConstantValue();
}

/// Common base class for all analyzer-internal classes that implement
/// `FieldElement`.
abstract class FieldElementOrMember implements PropertyInducingElementOrMember {
  @override
  FieldFragmentImpl get declaration;

  @override
  TypeImpl get type;
}

class FieldFormalParameterElementImpl extends FormalParameterElementImpl
    implements FieldFormalParameterElement {
  FieldFormalParameterElementImpl(super.firstFragment);

  @override
  FieldElementImpl? get field2 => switch (firstFragment) {
    FieldFormalParameterFragmentImpl(:FieldFragmentImpl field) => field.element,
    _ => null,
  };

  @override
  FieldFormalParameterFragmentImpl get firstFragment =>
      super.firstFragment as FieldFormalParameterFragmentImpl;

  @override
  List<FieldFormalParameterFragmentImpl> get fragments {
    return [
      for (
        FieldFormalParameterFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }
}

abstract class FieldFormalParameterElementOrMember
    implements ParameterElementMixin {
  /// The field element associated with this field formal parameter, or `null`
  /// if the parameter references a field that doesn't exist.
  FieldElementOrMember? get field;
}

class FieldFormalParameterFragmentImpl extends FormalParameterFragmentImpl
    implements
        FieldFormalParameterElementOrMember,
        FieldFormalParameterFragment {
  @override
  FieldFragmentImpl? field;

  /// Initialize a newly created parameter element to have the given [name] and
  /// [nameOffset].
  FieldFormalParameterFragmentImpl({
    required super.nameOffset,
    required super.name2,
    required super.nameOffset2,
    required super.parameterKind,
  });

  @override
  FieldFormalParameterElementImpl get element =>
      super.element as FieldFormalParameterElementImpl;

  /// Initializing formals are visible only in the "formal parameter
  /// initializer scope", which is the current scope of the initializer list
  /// of the constructor, and which is enclosed in the scope where the
  /// constructor is declared. And according to the specification, they
  /// introduce final local variables, always, regardless whether the field
  /// is final.
  @override
  bool get isFinal => true;

  @override
  bool get isInitializingFormal => true;

  @override
  FieldFormalParameterFragmentImpl? get nextFragment =>
      super.nextFragment as FieldFormalParameterFragmentImpl?;

  @override
  FieldFormalParameterFragmentImpl? get previousFragment =>
      super.previousFragment as FieldFormalParameterFragmentImpl?;

  @override
  FieldFormalParameterElementImpl _createElement(
    FormalParameterFragment firstFragment,
  ) => FieldFormalParameterElementImpl(
    firstFragment as FormalParameterFragmentImpl,
  );
}

class FieldFragmentImpl extends PropertyInducingFragmentImpl
    with ConstVariableFragment
    implements FieldElementOrMember, FieldFragment {
  /// True if this field inherits from a covariant parameter. This happens
  /// when it overrides a field in a supertype that is covariant.
  bool inheritsCovariant = false;

  @override
  late final FieldElementImpl element;

  /// Initialize a newly created synthetic field element to have the given
  /// [name] at the given [offset].
  FieldFragmentImpl({required super.name2, required super.nameOffset});

  @override
  ExpressionImpl? get constantInitializer {
    _ensureReadResolution();
    return super.constantInitializer;
  }

  @override
  FieldFragmentImpl get declaration => this;

  /// Whether the type of this fragment references a type parameter of the
  /// enclosing element. This includes not only explicitly specified type
  /// annotations, but also inferred types.
  bool get hasEnclosingTypeParameterReference {
    return !hasModifier(Modifier.NO_ENCLOSING_TYPE_PARAMETER_REFERENCE);
  }

  set hasEnclosingTypeParameterReference(bool value) {
    setModifier(Modifier.NO_ENCLOSING_TYPE_PARAMETER_REFERENCE, !value);
  }

  /// Whether the field is abstract.
  ///
  /// Executable fields are abstract if they are declared with the `abstract`
  /// keyword.
  bool get isAbstract {
    return hasModifier(Modifier.ABSTRACT);
  }

  /// Whether the field was explicitly marked as being covariant.
  bool get isCovariant {
    return hasModifier(Modifier.COVARIANT);
  }

  /// Set whether this field is explicitly marked as being covariant.
  set isCovariant(bool isCovariant) {
    setModifier(Modifier.COVARIANT, isCovariant);
  }

  /// Whether the element is an enum constant.
  bool get isEnumConstant {
    return hasModifier(Modifier.ENUM_CONSTANT);
  }

  set isEnumConstant(bool isEnumConstant) {
    setModifier(Modifier.ENUM_CONSTANT, isEnumConstant);
  }

  /// Whether the field was explicitly marked as being external.
  bool get isExternal {
    return hasModifier(Modifier.EXTERNAL);
  }

  /// Whether the field can be type promoted.
  bool get isPromotable {
    return hasModifier(Modifier.PROMOTABLE);
  }

  set isPromotable(bool value) {
    setModifier(Modifier.PROMOTABLE, value);
  }

  /// Return `true` if this element is a synthetic enum field.
  ///
  /// It is synthetic because it is not written explicitly in code, but it
  /// is different from other synthetic fields, because its getter is also
  /// synthetic.
  ///
  /// Such fields are `index`, `_name`, and `values`.
  bool get isSyntheticEnumField {
    return enclosingElement3 is EnumFragmentImpl &&
        isSynthetic &&
        element.getter2?.isSynthetic == true &&
        setter == null;
  }

  @override
  ElementKind get kind => ElementKind.FIELD;

  @override
  LibraryElementImpl get library2 => library;

  @override
  MetadataImpl get metadata {
    _ensureReadResolution();
    return super.metadata;
  }

  @override
  FieldFragmentImpl? get nextFragment =>
      super.nextFragment as FieldFragmentImpl?;

  @override
  int get offset => isSynthetic ? enclosingFragment.offset : _nameOffset;

  @override
  FieldFragmentImpl? get previousFragment =>
      super.previousFragment as FieldFragmentImpl?;

  void addFragment(FieldFragmentImpl fragment) {
    fragment.element = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }
}

class FormalParameterElementImpl extends PromotableElementImpl
    with
        FragmentedAnnotatableElementMixin<FormalParameterFragment>,
        FragmentedElementMixin<FormalParameterFragment>,
        FormalParameterElementMixin,
        _HasSinceSdkVersionMixin,
        _NonTopLevelVariableOrParameter {
  @override
  Reference? reference;

  final FormalParameterFragmentImpl wrappedElement;

  FormalParameterElementImpl(this.wrappedElement) {
    FormalParameterFragmentImpl? fragment = wrappedElement;
    while (fragment != null) {
      fragment.element = this;
      fragment = fragment.nextFragment;
    }
  }

  /// Creates a synthetic parameter with [name], [type] and [parameterKind].
  factory FormalParameterElementImpl.synthetic(
    String? name,
    TypeImpl type,
    ParameterKind parameterKind,
  ) {
    var fragment = FormalParameterFragmentImpl.synthetic(
      name,
      type,
      parameterKind,
    );
    return FormalParameterElementImpl(fragment);
  }

  @override
  FormalParameterElementImpl get baseElement => this;

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  String? get defaultValueCode => wrappedElement.defaultValueCode;

  @override
  FormalParameterFragmentImpl get firstFragment => wrappedElement;

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  List<FormalParameterElementImpl> get formalParameters =>
      wrappedElement.parameters.map((fragment) => fragment.element).toList();

  @override
  List<FormalParameterFragmentImpl> get fragments {
    return [
      for (
        FormalParameterFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  bool get hasDefaultValue => wrappedElement.hasDefaultValue;

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  bool get hasImplicitType => wrappedElement.hasImplicitType;

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  bool get isConst => wrappedElement.isConst;

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  bool get isCovariant => wrappedElement.isCovariant;

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  bool get isFinal => wrappedElement.isFinal;

  @override
  bool get isInitializingFormal => wrappedElement.isInitializingFormal;

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  bool get isLate => wrappedElement.isLate;

  @override
  bool get isNamed => wrappedElement.isNamed;

  @override
  bool get isOptional => wrappedElement.isOptional;

  @override
  bool get isOptionalNamed => wrappedElement.isOptionalNamed;

  @override
  bool get isOptionalPositional => wrappedElement.isOptionalPositional;

  @override
  bool get isPositional => wrappedElement.isPositional;

  @override
  bool get isRequired => wrappedElement.isRequired;

  @override
  bool get isRequiredNamed => wrappedElement.isRequiredNamed;

  @override
  bool get isRequiredPositional => wrappedElement.isRequiredPositional;

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  bool get isStatic => wrappedElement.isStatic;

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  bool get isSuperFormal => wrappedElement.isSuperFormal;

  @override
  ElementKind get kind => ElementKind.PARAMETER;

  @override
  LibraryElementImpl? get library2 => wrappedElement.library;

  @override
  String? get name3 {
    return wrappedElement.name2;
  }

  @override
  String get nameShared => wrappedElement.name2 ?? '';

  @override
  ParameterKind get parameterKind {
    return firstFragment.parameterKind;
  }

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  TypeImpl get type => wrappedElement.type;

  set type(TypeImpl value) {
    wrappedElement.type = value;
  }

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  List<TypeParameterElement> get typeParameters2 => const [];

  @override
  TypeImpl get typeShared => type;

  @override
  FragmentImpl? get _enclosingFunction => wrappedElement.enclosingElement3;

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitFormalParameterElement(this);
  }

  @override
  // TODO(augmentations): Implement the merge of formal parameters.
  DartObject? computeConstantValue() => wrappedElement.computeConstantValue();

  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {
    for (var child in children2) {
      child.accept2(visitor);
    }
  }

  // firstFragment.typeParameters
  //     .map((fragment) => (fragment as TypeParameterElementImpl).element)
  //     .toList();
}

/// A mixin that provides a common implementation for methods defined in
/// [FormalParameterElement].
mixin FormalParameterElementMixin
    implements
        FormalParameterElement,
        SharedNamedFunctionParameter,
        VariableElement2OrMember {
  @override
  FormalParameterElementImpl get baseElement;

  ParameterKind get parameterKind;

  @override
  TypeImpl get type;

  @override
  void appendToWithoutDelimiters2(StringBuffer buffer) {
    buffer.write(type.getDisplayString());
    buffer.write(' ');
    buffer.write(displayName);
    if (defaultValueCode != null) {
      buffer.write(' = ');
      buffer.write(defaultValueCode);
    }
  }
}

class FormalParameterFragmentImpl extends VariableFragmentImpl
    with ParameterElementMixin
    implements FormalParameterFragment {
  @override
  final String? name2;

  @override
  int? nameOffset2;

  @override
  MetadataImpl metadata = MetadataImpl(const []);

  /// A list containing all of the parameters defined by this parameter element.
  /// There will only be parameters if this parameter is a function typed
  /// parameter.
  List<FormalParameterFragmentImpl> _parameters = const [];

  /// A list containing all of the type parameters defined for this parameter
  /// element. There will only be parameters if this parameter is a function
  /// typed parameter.
  List<TypeParameterFragmentImpl> _typeParameters = const [];

  @override
  final ParameterKind parameterKind;

  @override
  String? defaultValueCode;

  /// True if this parameter inherits from a covariant parameter. This happens
  /// when it overrides a method in a supertype that has a corresponding
  /// covariant parameter.
  bool inheritsCovariant = false;

  /// The element corresponding to this fragment.
  FormalParameterElementImpl? _element;

  /// Initialize a newly created parameter element to have the given [name] and
  /// [nameOffset].
  FormalParameterFragmentImpl({
    required super.nameOffset,
    required this.name2,
    required this.nameOffset2,
    required this.parameterKind,
  }) : assert(nameOffset2 == null || nameOffset2 >= 0),
       assert(name2 == null || name2.isNotEmpty);

  /// Creates a synthetic parameter with [name2], [type] and [parameterKind].
  factory FormalParameterFragmentImpl.synthetic(
    String? name2,
    TypeImpl type,
    ParameterKind parameterKind,
  ) {
    // TODO(dantup): This does not keep any reference to the non-synthetic
    //  parameter which prevents navigation/references from working. See
    //  https://github.com/dart-lang/sdk/issues/60200
    var element = FormalParameterFragmentImpl(
      nameOffset: -1,
      name2: name2,
      nameOffset2: null,
      parameterKind: parameterKind,
    );
    element.type = type;
    element.isSynthetic = true;
    return element;
  }

  @override
  List<Fragment> get children3 => const [];

  @override
  FormalParameterFragmentImpl get declaration => this;

  @override
  FormalParameterElementImpl get element {
    if (_element != null) {
      return _element!;
    }
    FormalParameterFragment firstFragment = this;
    var previousFragment = firstFragment.previousFragment;
    while (previousFragment != null) {
      firstFragment = previousFragment;
      previousFragment = firstFragment.previousFragment;
    }
    // As a side-effect of creating the element, all of the fragments in the
    // chain will have their `_element` set to the newly created element.
    return _createElement(firstFragment);
  }

  set element(FormalParameterElementImpl element) => _element = element;

  @override
  Fragment? get enclosingFragment => enclosingElement3 as Fragment?;

  /// Whether the parameter has a default value.
  bool get hasDefaultValue {
    return defaultValueCode != null;
  }

  @override
  bool get isCovariant {
    if (isExplicitlyCovariant || inheritsCovariant) {
      return true;
    }
    return false;
  }

  /// Return true if this parameter is explicitly marked as being covariant.
  bool get isExplicitlyCovariant {
    return hasModifier(Modifier.COVARIANT);
  }

  /// Set whether this variable parameter is explicitly marked as being
  /// covariant.
  set isExplicitlyCovariant(bool isCovariant) {
    setModifier(Modifier.COVARIANT, isCovariant);
  }

  @override
  bool get isInitializingFormal => false;

  @override
  bool get isLate => false;

  /// Whether the parameter is a super formal parameter.
  bool get isSuperFormal => false;

  @override
  ElementKind get kind => ElementKind.PARAMETER;

  @override
  LibraryElementImpl? get library {
    var library = libraryFragment?.element;
    return library as LibraryElementImpl?;
  }

  @override
  LibraryElementImpl? get library2 => library;

  @override
  LibraryFragment? get libraryFragment {
    return enclosingFragment?.libraryFragment;
  }

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  // TODO(augmentations): Support chaining between the fragments.
  FormalParameterFragmentImpl? get nextFragment => null;

  @override
  List<FormalParameterFragmentImpl> get parameters {
    return _parameters;
  }

  /// Set the parameters defined by this executable element to the given
  /// [parameters].
  set parameters(List<FormalParameterFragmentImpl> parameters) {
    for (var parameter in parameters) {
      parameter.enclosingElement3 = this;
    }
    _parameters = parameters;
  }

  @override
  // TODO(augmentations): Support chaining between the fragments.
  FormalParameterFragmentImpl? get previousFragment => null;

  @override
  List<TypeParameterFragmentImpl> get typeParameters {
    return _typeParameters;
  }

  /// Set the type parameters defined by this parameter element to the given
  /// [typeParameters].
  set typeParameters(List<TypeParameterFragmentImpl> typeParameters) {
    for (var parameter in typeParameters) {
      parameter.enclosingElement3 = this;
    }
    _typeParameters = typeParameters;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeFormalParameter(this);
  }

  FormalParameterElementImpl _createElement(
    FormalParameterFragment firstFragment,
  ) => FormalParameterElementImpl(firstFragment as FormalParameterFragmentImpl);
}

/// The parameter of an implicit setter.
class FormalParameterFragmentImplOfImplicitSetter
    extends FormalParameterFragmentImpl {
  final PropertyAccessorFragmentImplImplicitSetter setter;

  FormalParameterFragmentImplOfImplicitSetter(this.setter)
    : super(
        nameOffset: -1,
        name2:
            setter.variable2.name2 == null
                ? null
                : considerCanonicalizeString('_${setter.variable2.name2!}'),
        nameOffset2: null,
        parameterKind: ParameterKind.REQUIRED,
      ) {
    enclosingElement3 = setter;
    isSynthetic = true;
  }

  @override
  bool get inheritsCovariant {
    var variable = setter.variable2;
    if (variable is FieldFragmentImpl) {
      return variable.inheritsCovariant;
    }
    return false;
  }

  @override
  set inheritsCovariant(bool value) {
    var variable = setter.variable2;
    if (variable is FieldFragmentImpl) {
      variable.inheritsCovariant = value;
    }
  }

  @override
  bool get isCovariant {
    if (isExplicitlyCovariant || inheritsCovariant) {
      return true;
    }
    return false;
  }

  @override
  bool get isExplicitlyCovariant {
    var variable = setter.variable2;
    if (variable is FieldFragmentImpl) {
      return variable.isCovariant;
    }
    return false;
  }

  @override
  FragmentImpl get nonSynthetic {
    return setter.variable2;
  }

  @override
  int get offset => setter.offset;

  @override
  TypeImpl get type => setter.variable2.type;

  @override
  set type(DartType type) {
    assert(false); // Should never be called.
  }
}

mixin FragmentedAnnotatableElementMixin<E extends Fragment>
    implements FragmentedElementMixin<E> {
  String? get documentationComment {
    var buffer = StringBuffer();
    for (var fragment in _fragments) {
      var comment = fragment.documentationCommentOrNull;
      if (comment != null) {
        if (buffer.isNotEmpty) {
          buffer.writeln();
          buffer.writeln();
        }
        buffer.write(comment);
      }
    }
    if (buffer.isEmpty) {
      return null;
    }
    return buffer.toString();
  }

  MetadataImpl get metadata {
    var annotations = <ElementAnnotationImpl>[];
    for (var fragment in _fragments) {
      switch (fragment) {
        case AnnotatableFragmentImpl fragment:
          annotations.addAll(fragment.metadata.annotations);
        default:
          throw StateError('Must have annotatable fragments');
      }
    }
    return MetadataImpl(annotations);
  }

  @Deprecated('Use metadata instead')
  MetadataImpl get metadata2 => metadata;

  Version? get sinceSdkVersion {
    if (this is Element) {
      return SinceSdkVersionComputer().compute(this as Element);
    }
    return null;
  }
}

mixin FragmentedElementMixin<E extends Fragment> implements _Fragmented<E> {
  bool get isSynthetic {
    if (firstFragment is FragmentImpl) {
      return (firstFragment as FragmentImpl).isSynthetic;
    }
    // We should never get to this point.
    assert(false, 'Fragment does not implement ElementImpl');
    return false;
  }

  /// A list of all of the fragments from which this element is composed.
  List<E> get _fragments {
    var result = <E>[];
    E? current = firstFragment;
    while (current != null) {
      result.add(current);
      current = current.nextFragment as E?;
    }
    return result;
  }

  String displayString2({
    bool multiline = false,
    bool preferTypeAlias = false,
  }) {
    var builder = ElementDisplayStringBuilder(
      multiline: multiline,
      preferTypeAlias: preferTypeAlias,
    );
    var fragment = firstFragment;
    if (fragment is! FragmentImpl) {
      throw UnsupportedError('Fragment is not an ElementImpl');
    }
    (fragment as FragmentImpl).appendTo(builder);
    return builder.toString();
  }
}

mixin FragmentedExecutableElementMixin<E extends ExecutableFragmentImpl>
    implements FragmentedElementMixin<E> {
  List<FormalParameterElementMixin> get formalParameters {
    return firstFragment.formalParameters
        .map((fragment) => fragment.asElement2)
        .toList();
  }

  bool get hasImplicitReturnType {
    for (var fragment in _fragments) {
      if (!(fragment as ExecutableFragmentImpl).hasImplicitReturnType) {
        return false;
      }
    }
    return true;
  }

  bool get isAbstract {
    for (var fragment in _fragments) {
      if (!(fragment as ExecutableFragmentImpl).isAbstract) {
        return false;
      }
    }
    return true;
  }

  bool get isExtensionTypeMember =>
      (firstFragment as ExecutableFragmentImpl).isExtensionTypeMember;

  bool get isExternal {
    for (var fragment in _fragments) {
      if ((fragment as ExecutableFragmentImpl).isExternal) {
        return true;
      }
    }
    return false;
  }

  bool get isStatic => (firstFragment as ExecutableFragmentImpl).isStatic;
}

mixin FragmentedFunctionTypedElementMixin<E extends ExecutableFragment>
    implements FragmentedElementMixin<E> {
  // TODO(augmentations): This might be wrong. The parameters need to be a
  //  merge of the parameters of all of the fragments, but this probably doesn't
  //  account for missing data (such as the parameter types).
  List<FormalParameterElementMixin> get formalParameters {
    var fragment = firstFragment;
    return switch (fragment) {
      FunctionTypedFragmentImpl(:var parameters) =>
        parameters.map((fragment) => fragment.asElement2).toList(),
      ExecutableFragmentImpl(:var parameters) =>
        parameters.map((fragment) => fragment.asElement2).toList(),
      _ =>
        throw UnsupportedError(
          'Cannot get formal parameters for ${fragment.runtimeType}',
        ),
    };
  }

  // TODO(augmentations): This is wrong. The function type needs to be a merge
  //  of the function types of all of the fragments, but I don't know how to
  //  perform that merge.
  FunctionTypeImpl get type {
    if (firstFragment is ExecutableFragmentImpl) {
      return (firstFragment as ExecutableFragmentImpl).type;
    } else if (firstFragment is FunctionTypedFragmentImpl) {
      return (firstFragment as FunctionTypedFragmentImpl).type;
    }
    throw UnimplementedError();
  }
}

mixin FragmentedTypeParameterizedElementMixin<
  E extends TypeParameterizedFragment
>
    implements FragmentedElementMixin<E> {
  bool get isSimplyBounded {
    var fragment = firstFragment;
    if (fragment is TypeParameterizedFragmentMixin) {
      return fragment.isSimplyBounded;
    }
    return true;
  }

  List<TypeParameterElement> get typeParameters2 {
    var fragment = firstFragment;
    if (fragment is TypeParameterizedFragmentMixin) {
      return fragment.typeParameters
          .map((fragment) => (fragment as TypeParameterFragment).element)
          .toList();
    }
    return const [];
  }
}

abstract class FragmentImpl implements FragmentOrMember {
  static int _NEXT_ID = 0;

  @override
  final int id = _NEXT_ID++;

  /// The element that either physically or logically encloses this element.
  ///
  /// For [LibraryElement] returns `null`, because libraries are the top-level
  /// elements in the model.
  ///
  /// For [CompilationUnitElement] returns the [CompilationUnitElement] that
  /// uses `part` directive to include this element, or `null` if this element
  /// is the defining unit of the library.
  FragmentImpl? enclosingElement3;

  /// The offset of the name of this element in the file that contains the
  /// declaration of this element.
  int _nameOffset = 0;

  /// The modifiers associated with this element.
  EnumSet<Modifier> _modifiers = EnumSet.empty();

  /// The documentation comment for this element.
  String? _docComment;

  /// The offset of the beginning of the element's code in the file that
  /// contains the element, or `null` if the element is synthetic.
  int? _codeOffset;

  /// The length of the element's code, or `null` if the element is synthetic.
  int? _codeLength;

  /// Initialize a newly created element to have the given [name] at the given
  /// [_nameOffset].
  FragmentImpl({required int nameOffset}) : _nameOffset = nameOffset;

  /// The length of the element's code, or `null` if the element is synthetic.
  int? get codeLength => _codeLength;

  /// The offset of the beginning of the element's code in the file that
  /// contains the element, or `null` if the element is synthetic.
  int? get codeOffset => _codeOffset;

  @override
  AnalysisContext get context {
    return library!.context;
  }

  @override
  FragmentImpl get declaration => this;

  @override
  String get displayName => name2 ?? '';

  @override
  String? get documentationComment => _docComment;

  /// The documentation comment source for this element.
  set documentationComment(String? doc) {
    _docComment = doc;
  }

  /// Return the enclosing unit element (which might be the same as `this`), or
  /// `null` if this element is not contained in any compilation unit.
  LibraryFragmentImpl get enclosingUnit {
    return enclosingElement3!.enclosingUnit;
  }

  /// Return an identifier that uniquely identifies this element among the
  /// children of this element's parent.
  String get identifier {
    var identifier = name2 ?? '';

    if (_includeNameOffsetInIdentifier) {
      identifier += "@$nameOffset";
    }

    return considerCanonicalizeString(identifier);
  }

  bool get isNonFunctionTypeAliasesEnabled {
    return library!.featureSet.isEnabled(Feature.nonfunction_type_aliases);
  }

  @override
  bool get isPrivate {
    var name = name2;
    if (name == null) {
      return false;
    }
    return Identifier.isPrivateName(name);
  }

  @override
  bool get isPublic => !isPrivate;

  @override
  bool get isSynthetic {
    return hasModifier(Modifier.SYNTHETIC);
  }

  /// Set whether this element is synthetic.
  set isSynthetic(bool isSynthetic) {
    setModifier(Modifier.SYNTHETIC, isSynthetic);
  }

  LibraryElementImpl? get library;

  @override
  Source? get librarySource => library?.source;

  String? get lookupName {
    return name2;
  }

  @override
  int get nameLength => displayName.length;

  @override
  int get nameOffset => _nameOffset;

  /// Sets the offset of the name of this element in the file that contains the
  /// declaration of this element.
  set nameOffset(int offset) {
    _nameOffset = offset;
  }

  /// The non-synthetic element that caused this element to be created.
  ///
  /// If this element is not synthetic, then the element itself is returned.
  ///
  /// If this element is synthetic, then the corresponding non-synthetic
  /// element is returned. For example, for a synthetic getter of a
  /// non-synthetic field the field is returned; for a synthetic constructor
  /// the enclosing class is returned.
  FragmentImpl get nonSynthetic => this;

  @override
  AnalysisSession? get session {
    return enclosingElement3?.session;
  }

  @override
  Version? get sinceSdkVersion {
    return asElement2.ifTypeOrNull<HasSinceSdkVersion>()?.sinceSdkVersion;
  }

  @override
  Source? get source {
    return enclosingElement3?.source;
  }

  /// Whether to include the [nameOffset] in [identifier] to disambiguate
  /// elements that might otherwise have the same identifier.
  bool get _includeNameOffsetInIdentifier {
    return false;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other);
  }

  /// Append a textual representation of this element to the given [builder].
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeAbstractElement(this);
  }

  /// Set this element as the enclosing element for given [element].
  void encloseElement(FragmentImpl element) {
    element.enclosingElement3 = this;
  }

  /// Set this element as the enclosing element for given [elements].
  void encloseElements(List<FragmentImpl> elements) {
    for (var element in elements) {
      element.enclosingElement3 = this;
    }
  }

  @override
  String getDisplayString({
    @Deprecated('Only non-nullable by default mode is supported')
    bool withNullability = true,
    bool multiline = false,
    bool preferTypeAlias = false,
  }) {
    var builder = ElementDisplayStringBuilder(
      multiline: multiline,
      preferTypeAlias: preferTypeAlias,
    );
    appendTo(builder);
    return builder.toString();
  }

  /// Return `true` if this element has the given [modifier] associated with it.
  bool hasModifier(Modifier modifier) => _modifiers[modifier];

  void readModifiers(SummaryDataReader reader) {
    _modifiers = EnumSet(reader.readInt64());
  }

  /// Set the code range for this element.
  void setCodeRange(int offset, int length) {
    _codeOffset = offset;
    _codeLength = length;
  }

  /// Set whether the given [modifier] is associated with this element to
  /// correspond to the given [value].
  void setModifier(Modifier modifier, bool value) {
    _modifiers = _modifiers.updated(modifier, value);
  }

  @override
  String toString() {
    return getDisplayString();
  }

  void writeModifiers(BufferedSink writer) {
    _modifiers.write(writer);
  }
}

/// A shared internal interface of `Element` and [Member].
/// Used during migration to avoid referencing `Element`.
abstract class FragmentOrMember implements Fragment {
  /// The analysis context in which this element is defined.
  AnalysisContext get context;

  /// The declaration of this element.
  ///
  /// If the element is a view on an element, e.g. a method from an interface
  /// type, with substituted type parameters, return the corresponding element
  /// from the class, without any substitutions. If this element is already a
  /// declaration (or a synthetic element, e.g. a synthetic property accessor),
  /// return itself.
  FragmentOrMember? get declaration;

  /// The display name of this element, possibly the empty string if the
  /// element does not have a name.
  ///
  /// In most cases the name and the display name are the same. Differences
  /// though are cases such as setters where the name of some setter `set f(x)`
  /// is `f=`, instead of `f`.
  String get displayName;

  /// The content of the documentation comment (including delimiters) for this
  /// element, or `null` if this element does not or cannot have documentation.
  String? get documentationComment;

  /// The unique integer identifier of this element.
  int get id;

  /// Whether the element is private.
  ///
  /// Private elements are visible only within the library in which they are
  /// declared.
  bool get isPrivate;

  /// Whether the element is public.
  ///
  /// Public elements are visible within any library that imports the library
  /// in which they are declared.
  bool get isPublic;

  /// Whether the element is synthetic.
  ///
  /// A synthetic element is an element that is not represented in the source
  /// code explicitly, but is implied by the source code, such as the default
  /// constructor for a class that does not explicitly define any constructors.
  bool get isSynthetic;

  /// The kind of element that this is.
  ElementKind get kind;

  /// If this target is associated with a library, return the source of the
  /// library's defining compilation unit; otherwise return `null`.
  Source? get librarySource;

  /// The length of the name of this element in the file that contains the
  /// declaration of this element, or `0` if this element does not have a name.
  int get nameLength;

  /// The offset of the name of this element in the file that contains the
  /// declaration of this element, or `-1` if this element is synthetic, does
  /// not have a name, or otherwise does not have an offset.
  int get nameOffset;

  /// The analysis session in which this element is defined.
  AnalysisSession? get session;

  /// The version where this SDK API was added.
  ///
  /// A `@Since()` annotation can be applied to a library declaration,
  /// any public declaration in a library, or in a class, or to an optional
  /// parameter, etc.
  ///
  /// The returned version is "effective", so that if a library is annotated
  /// then all elements of the library inherit it; or if a class is annotated
  /// then all members and constructors of the class inherit it.
  ///
  /// If multiple `@Since()` annotations apply to the same element, the latest
  /// version takes precedence.
  ///
  /// Returns `null` if the element is not declared in SDK, or does not have
  /// a `@Since()` annotation applicable to it.
  Version? get sinceSdkVersion;

  /// Return the source associated with this target, or `null` if this target is
  /// not associated with a source.
  Source? get source;

  /// Returns the presentation of this element as it should appear when
  /// presented to users.
  ///
  /// If [withNullability] is `true`, then [NullabilitySuffix.question] and
  /// [NullabilitySuffix.star] in types will be represented as `?` and `*`.
  /// [NullabilitySuffix.none] does not have any explicit presentation.
  ///
  /// If [withNullability] is `false`, nullability suffixes will not be
  /// included into the presentation.
  ///
  /// If [multiline] is `true`, the string may be wrapped over multiple lines
  /// with newlines to improve formatting. For example function signatures may
  /// be formatted as if they had trailing commas.
  ///
  /// Clients should not depend on the content of the returned value as it will
  /// be changed if doing so would improve the UX.
  String getDisplayString({
    @Deprecated('Only non-nullable by default mode is supported')
    bool withNullability = true,
    bool multiline = false,
  });
}

sealed class FunctionFragmentImpl extends ExecutableFragmentImpl
    implements FunctionTypedFragmentImpl, ExecutableElementOrMember {
  @override
  final String? name2;

  @override
  int? nameOffset2;

  /// Initialize a newly created function element to have the given [name] and
  /// [offset].
  FunctionFragmentImpl({required this.name2, required super.nameOffset});

  /// Initialize a newly created function element to have no name and the given
  /// [nameOffset]. This is used for function expressions, that have no name.
  FunctionFragmentImpl.forOffset(int nameOffset)
    : name2 = null,
      super(nameOffset: nameOffset);

  @override
  ExecutableFragmentImpl get declaration => this;

  @override
  Fragment? get enclosingFragment {
    switch (enclosingElement3) {
      case LibraryFragment libraryFragment:
        // TODO(augmentations): Support the fragment chain.
        return libraryFragment;
      case ExecutableFragment executableFragment:
        return executableFragment;
      case LocalVariableFragment variableFragment:
        return variableFragment;
      case FormalParameterFragmentImpl parameterFragment:
        return parameterFragment;
      case TopLevelVariableFragment variableFragment:
        return variableFragment;
      case FieldFragment fieldFragment:
        return fieldFragment;
    }
    // Local functions cannot be augmented.
    throw UnsupportedError('This is not a fragment');
  }

  @override
  ElementKind get kind => ElementKind.FUNCTION;
}

abstract class FunctionTypedElementImpl extends TypeParameterizedElementImpl
    implements FunctionTypedElement {
  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {
    for (var child in children2) {
      child.accept2(visitor);
    }
  }
}

/// Common internal interface shared by elements whose type is a function type.
///
/// Clients may not extend, implement or mix-in this class.
abstract class FunctionTypedFragmentImpl implements _ExistingFragmentImpl {
  /// The parameters defined by this executable element.
  List<FormalParameterFragmentImpl> get parameters;

  set returnType(DartType returnType);

  /// The type defined by this element.
  FunctionTypeImpl get type;

  /// The type parameters declared by this element directly.
  ///
  /// This does not include type parameters that are declared by any enclosing
  /// elements.
  List<TypeParameterFragmentImpl> get typeParameters;
}

/// The element used for a generic function type.
///
/// Clients may not extend, implement or mix-in this class.
class GenericFunctionTypeElementImpl extends FunctionTypedElementImpl
    implements GenericFunctionTypeElement {
  final GenericFunctionTypeFragmentImpl _wrappedElement;

  GenericFunctionTypeElementImpl(this._wrappedElement);

  @override
  String? get documentationComment => _wrappedElement.documentationComment;

  @override
  Element? get enclosingElement => firstFragment.enclosingFragment?.element;

  @Deprecated('Use enclosingElement instead')
  @override
  Element? get enclosingElement2 => enclosingElement;

  @override
  GenericFunctionTypeFragmentImpl get firstFragment => _wrappedElement;

  @override
  List<FormalParameterElement> get formalParameters =>
      _wrappedElement.formalParameters
          .map((fragment) => fragment.element)
          .toList();

  @override
  List<GenericFunctionTypeFragmentImpl> get fragments {
    return [
      for (
        GenericFunctionTypeFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  bool get isSimplyBounded => _wrappedElement.isSimplyBounded;

  @override
  bool get isSynthetic => _wrappedElement.isSynthetic;

  @override
  ElementKind get kind => _wrappedElement.kind;

  @override
  LibraryElementImpl get library2 => _wrappedElement.library;

  @override
  MetadataImpl get metadata => _wrappedElement.metadata;

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  String? get name3 => _wrappedElement.name2;

  @override
  DartType get returnType => _wrappedElement.returnType;

  @override
  FunctionType get type => _wrappedElement.type;

  @override
  List<TypeParameterElement> get typeParameters2 =>
      _wrappedElement.typeParameters2
          .map((fragment) => fragment.element)
          .toList();

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitGenericFunctionTypeElement(this);
  }
}

/// The element used for a generic function type.
///
/// Clients may not extend, implement or mix-in this class.
class GenericFunctionTypeFragmentImpl extends _ExistingFragmentImpl
    with DeferredResolutionReadingMixin, TypeParameterizedFragmentMixin
    implements FunctionTypedFragmentImpl, GenericFunctionTypeFragment {
  /// The declared return type of the function.
  TypeImpl? _returnType;

  /// The elements representing the parameters of the function.
  List<FormalParameterFragmentImpl> _parameters = const [];

  /// Is `true` if the type has the question mark, so is nullable.
  bool isNullable = false;

  /// The type defined by this element.
  FunctionTypeImpl? _type;

  late final GenericFunctionTypeElementImpl _element2 =
      GenericFunctionTypeElementImpl(this);

  /// Initialize a newly created function element to have no name and the given
  /// [nameOffset]. This is used for function expressions, that have no name.
  GenericFunctionTypeFragmentImpl.forOffset(int nameOffset)
    : super(nameOffset: nameOffset);

  @override
  List<Fragment> get children3 => [...typeParameters, ...parameters];

  @override
  GenericFunctionTypeElementImpl get element => _element2;

  @override
  Fragment? get enclosingFragment => enclosingElement3 as Fragment;

  @override
  List<FormalParameterFragmentImpl> get formalParameters => parameters;

  @override
  String get identifier => '-';

  @override
  ElementKind get kind => ElementKind.GENERIC_FUNCTION_TYPE;

  @override
  String? get name2 => null;

  @override
  int? get nameOffset2 => null;

  @override
  GenericFunctionTypeFragmentImpl? get nextFragment => null;

  @override
  int get offset => _nameOffset;

  @override
  List<FormalParameterFragmentImpl> get parameters {
    return _parameters;
  }

  /// Set the parameters defined by this function type element to the given
  /// [parameters].
  set parameters(List<FormalParameterFragmentImpl> parameters) {
    for (var parameter in parameters) {
      parameter.enclosingElement3 = this;
    }
    _parameters = parameters;
  }

  @override
  GenericFunctionTypeFragmentImpl? get previousFragment => null;

  /// The return type defined by this element.
  TypeImpl get returnType {
    return _returnType!;
  }

  /// Set the return type defined by this function type element to the given
  /// [returnType].
  @override
  set returnType(DartType returnType) {
    // TODO(paulberry): eliminate this cast by changing the setter parameter
    // type to `TypeImpl`.
    _returnType = returnType as TypeImpl;
  }

  @override
  FunctionTypeImpl get type {
    if (_type != null) return _type!;

    return _type = FunctionTypeImpl(
      typeFormals: typeParameters,
      parameters: parameters.map((f) => f.asElement2).toList(),
      returnType: returnType,
      nullabilitySuffix:
          isNullable ? NullabilitySuffix.question : NullabilitySuffix.none,
    );
  }

  /// Set the function type defined by this function type element to the given
  /// [type].
  set type(FunctionTypeImpl type) {
    _type = type;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeGenericFunctionTypeElement(this);
  }
}

/// Common base class for all analyzer-internal classes that implement
/// [GetterElement].
abstract class GetterElement2OrMember
    implements PropertyAccessorElement2OrMember, GetterElement {
  @override
  GetterElementImpl get baseElement;
}

class GetterElementImpl extends PropertyAccessorElementImpl
    with
        FragmentedExecutableElementMixin<GetterFragmentImpl>,
        FragmentedFunctionTypedElementMixin<GetterFragmentImpl>,
        FragmentedTypeParameterizedElementMixin<GetterFragmentImpl>,
        FragmentedAnnotatableElementMixin<GetterFragmentImpl>,
        FragmentedElementMixin<GetterFragmentImpl>,
        _HasSinceSdkVersionMixin
    implements GetterElement2OrMember {
  @override
  Reference reference;

  @override
  final GetterFragmentImpl firstFragment;

  GetterElementImpl(this.reference, this.firstFragment) {
    reference.element = this;
    GetterFragmentImpl? fragment = firstFragment;
    while (fragment != null) {
      fragment.element = this;
      fragment = fragment.nextFragment;
    }
  }

  @override
  GetterElementImpl get baseElement => this;

  @override
  SetterElement? get correspondingSetter2 {
    return variable3?.setter2;
  }

  @override
  List<GetterFragmentImpl> get fragments {
    return [
      for (
        GetterFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  ElementKind get kind => ElementKind.GETTER;

  @override
  GetterFragmentImpl get lastFragment {
    return super.lastFragment as GetterFragmentImpl;
  }

  @override
  Element get nonSynthetic {
    if (!isSynthetic) {
      return this;
    } else if (variable3 case var variable?) {
      return variable.nonSynthetic;
    }
    throw StateError('Synthetic getter has no variable');
  }

  @override
  Version? get sinceSdkVersion {
    if (isSynthetic) {
      return variable3?.sinceSdkVersion;
    }
    return super.sinceSdkVersion;
  }

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitGetterElement(this);
  }
}

class GetterFragmentImpl extends PropertyAccessorFragmentImpl
    implements GetterFragment {
  @override
  late GetterElementImpl element;

  @override
  GetterFragmentImpl? previousFragment;

  @override
  GetterFragmentImpl? nextFragment;

  GetterFragmentImpl({required super.name2, required super.nameOffset});

  GetterFragmentImpl.forVariable(super.variable) : super.forVariable();

  @override
  PropertyAccessorFragmentImpl? get correspondingGetter => null;

  @override
  PropertyAccessorFragmentImpl? get correspondingSetter => variable2?.setter;

  @override
  bool get isGetter => true;

  @override
  bool get isSetter => false;

  void addFragment(GetterFragmentImpl fragment) {
    fragment.element = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }
}

/// A concrete implementation of a [HideElementCombinator].
class HideElementCombinatorImpl implements HideElementCombinator {
  @override
  List<String> hiddenNames = const [];

  @override
  int offset = 0;

  @override
  int end = -1;

  @override
  String toString() {
    StringBuffer buffer = StringBuffer();
    buffer.write("hide ");
    int count = hiddenNames.length;
    for (int i = 0; i < count; i++) {
      if (i > 0) {
        buffer.write(", ");
      }
      buffer.write(hiddenNames[i]);
    }
    return buffer.toString();
  }
}

@elementClass
abstract class InstanceElementImpl extends ElementImpl
    with DeferredMembersReadingMixin, DeferredResolutionReadingMixin
    implements
        InstanceElement,
        TypeParameterizedElement,
        AnnotatableElementImpl {
  List<FieldElementImpl> _fields = [];
  List<GetterElementImpl> _getters = [];
  List<SetterElementImpl> _setters = [];
  List<MethodElementImpl> _methods = [];

  @override
  InstanceElement get baseElement => this;

  @override
  List<Element> get children2 {
    return [...fields, ...getters, ...setters, ...methods];
  }

  @override
  String get displayName => firstFragment.displayName;

  @override
  String? get documentationComment => firstFragment.documentationComment;

  @override
  LibraryElement get enclosingElement => firstFragment.library;

  @Deprecated('Use enclosingElement instead')
  @override
  LibraryElement get enclosingElement2 => enclosingElement;

  @override
  List<FieldElementImpl> get fields {
    globalResultRequirements?.record_instanceElement_fields(element: this);
    ensureReadMembers();
    return _fields;
  }

  set fields(List<FieldElementImpl> value) {
    _fields = value;
  }

  @Deprecated('Use fields instead')
  @override
  List<FieldElementImpl> get fields2 => fields;

  @override
  InstanceFragmentImpl get firstFragment;

  @override
  List<GetterElementImpl> get getters {
    globalResultRequirements?.record_instanceElement_getters(element: this);
    ensureReadMembers();
    return _getters;
  }

  set getters(List<GetterElementImpl> value) {
    _getters = value;
  }

  @Deprecated('Use getters instead')
  @override
  List<GetterElementImpl> get getters2 => getters;

  @override
  String get identifier => name3 ?? firstFragment.identifier;

  @override
  bool get isPrivate => firstFragment.isPrivate;

  @override
  bool get isPublic => firstFragment.isPublic;

  @override
  bool get isSimplyBounded => firstFragment.isSimplyBounded;

  @override
  bool get isSynthetic => firstFragment.isSynthetic;

  @override
  ElementKind get kind => firstFragment.kind;

  @override
  LibraryElementImpl get library2 => firstFragment.library;

  @override
  MetadataImpl get metadata => firstFragment.metadata;

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  @trackedDirectlyExpensive
  List<MethodElementImpl> get methods {
    globalResultRequirements?.record_instanceElement_methods(element: this);
    ensureReadMembers();
    return _methods;
  }

  set methods(List<MethodElementImpl> value) {
    _methods = value;
  }

  @Deprecated('Use methods instead')
  @override
  List<MethodElementImpl> get methods2 => methods;

  @override
  String? get name3 => firstFragment.name2;

  @override
  Element get nonSynthetic => isSynthetic ? enclosingElement : this as Element;

  @override
  AnalysisSession? get session => firstFragment.session;

  @override
  List<SetterElementImpl> get setters {
    globalResultRequirements?.record_instanceElement_setters(element: this);
    ensureReadMembers();
    return _setters;
  }

  set setters(List<SetterElementImpl> value) {
    _setters = value;
  }

  @Deprecated('Use setters instead')
  @override
  List<SetterElementImpl> get setters2 => setters;

  @override
  List<TypeParameterElementImpl> get typeParameters2 =>
      firstFragment.typeParameters.map((fragment) => fragment.element).toList();

  void addField(FieldElementImpl element) {
    // TODO(scheglov): optimize
    _fields = [..._fields, element];
  }

  void addGetter(GetterElementImpl element) {
    // TODO(scheglov): optimize
    _getters = [..._getters, element];
  }

  void addMethod(MethodElementImpl element) {
    // TODO(scheglov): optimize
    _methods = [..._methods, element];
  }

  void addSetter(SetterElementImpl element) {
    // TODO(scheglov): optimize
    _setters = [..._setters, element];
  }

  @override
  String displayString2({
    bool multiline = false,
    bool preferTypeAlias = false,
  }) => firstFragment.getDisplayString(
    multiline: multiline,
    preferTypeAlias: preferTypeAlias,
  );

  @override
  @trackedDirectly
  FieldElementImpl? getField(String name) {
    globalResultRequirements?.record_instanceElement_getField(
      element: this,
      name: name,
    );

    return globalResultRequirements.withoutRecording(
      reason: r'''
The result depends only on the requested field, which we have already
recorded above.
''',
      operation: () {
        return fields.firstWhereOrNull((e) => e.name3 == name);
      },
    );
  }

  @Deprecated('Use getField instead')
  @override
  FieldElementImpl? getField2(String name) => getField(name);

  @override
  @trackedDirectly
  GetterElementImpl? getGetter(String name) {
    globalResultRequirements?.record_instanceElement_getGetter(
      element: this,
      name: name,
    );

    return globalResultRequirements.withoutRecording(
      reason: r'''
The result depends only on the requested getter, which we have already
recorded above.
''',
      operation: () {
        return getters.firstWhereOrNull((e) => e.name3 == name);
      },
    );
  }

  @Deprecated('Use getGetter instead')
  @override
  GetterElementImpl? getGetter2(String name) => getGetter(name);

  @override
  @trackedDirectly
  MethodElementImpl? getMethod(String name) {
    globalResultRequirements?.record_instanceElement_getMethod(
      element: this,
      name: name,
    );

    return globalResultRequirements.withoutRecording(
      reason: r'''
The result depends only on the requested method, which we have already
recorded above.
''',
      operation: () {
        return methods.firstWhereOrNull((e) => e.lookupName == name);
      },
    );
  }

  @Deprecated('Use getMethod instead')
  @override
  MethodElementImpl? getMethod2(String name) => getMethod(name);

  @override
  @trackedDirectly
  SetterElementImpl? getSetter(String name) {
    globalResultRequirements?.record_instanceElement_getSetter(
      element: this,
      name: name,
    );

    return globalResultRequirements.withoutRecording(
      reason: r'''
The result depends only on the requested setter, which we have already
recorded above.
''',
      operation: () {
        return setters.firstWhereOrNull((e) => e.name3 == name);
      },
    );
  }

  @Deprecated('Use getSetter instead')
  @override
  SetterElementImpl? getSetter2(String name) => getSetter(name);

  @override
  bool isAccessibleIn2(LibraryElement library) {
    var name = name3;
    if (name != null && Identifier.isPrivateName(name)) {
      return library == library2;
    }
    return true;
  }

  @override
  GetterElement? lookUpGetter({
    required String name,
    required LibraryElement library,
  }) {
    return _implementationsOfGetter2(
          name,
        ).firstWhereOrNull((getter) => getter.isAccessibleIn2(library))
        as GetterElement?;
  }

  @Deprecated('Use lookUpGetter instead')
  @override
  GetterElement? lookUpGetter2({
    required String name,
    required LibraryElement library,
  }) {
    return lookUpGetter(name: name, library: library);
  }

  @override
  MethodElement? lookUpMethod({
    required String name,
    required LibraryElement library,
  }) {
    return _implementationsOfMethod2(
      name,
    ).firstWhereOrNull((method) => method.isAccessibleIn2(library));
  }

  @Deprecated('Use lookUpMethod instead')
  @override
  MethodElement? lookUpMethod2({
    required String name,
    required LibraryElement library,
  }) {
    return lookUpMethod(name: name, library: library);
  }

  @override
  SetterElement? lookUpSetter({
    required String name,
    required LibraryElement library,
  }) {
    return _implementationsOfSetter2(
          name,
        ).firstWhereOrNull((setter) => setter.isAccessibleIn2(library))
        as SetterElement?;
  }

  @Deprecated('Use lookUpSetter instead')
  @override
  SetterElement? lookUpSetter2({
    required String name,
    required LibraryElement library,
  }) {
    return lookUpSetter(name: name, library: library);
  }

  @override
  Element? thisOrAncestorMatching2(bool Function(Element) predicate) {
    if (predicate(this)) {
      return this;
    }
    return library2.thisOrAncestorMatching2(predicate);
  }

  @override
  E? thisOrAncestorOfType2<E extends Element>() {
    if (this case E result) {
      return result;
    }
    return library2.thisOrAncestorOfType2<E>();
  }

  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {
    for (var child in children2) {
      child.accept2(visitor);
    }
  }

  Iterable<PropertyAccessorElement2OrMember> _implementationsOfGetter2(
    String name,
  ) sync* {
    var visitedElements = <InstanceElement>{};
    InstanceElement? element = this;
    while (element != null && visitedElements.add(element)) {
      var getter = element.getGetter(name);
      if (getter != null) {
        yield getter as PropertyAccessorElement2OrMember;
      }
      if (element is! InterfaceElement) {
        return;
      }
      for (var mixin in element.mixins.reversed) {
        mixin as InterfaceTypeImpl;
        getter = mixin.element3.getGetter(name);
        if (getter != null) {
          yield getter as PropertyAccessorElement2OrMember;
        }
      }
      var supertype = element.firstFragment.supertype;
      supertype as InterfaceTypeImpl?;
      element = supertype?.element3;
    }
  }

  Iterable<MethodElement2OrMember> _implementationsOfMethod2(
    String name,
  ) sync* {
    var visitedElements = <InstanceElement>{};
    InstanceElement? element = this;
    while (element != null && visitedElements.add(element)) {
      var method = element.getMethod(name);
      if (method != null) {
        yield method as MethodElement2OrMember;
      }
      if (element is! InterfaceElement) {
        return;
      }
      for (var mixin in element.mixins.reversed) {
        mixin as InterfaceTypeImpl;
        method = mixin.element3.getMethod(name);
        if (method != null) {
          yield method as MethodElement2OrMember;
        }
      }
      var supertype = element.firstFragment.supertype;
      supertype as InterfaceTypeImpl?;
      element = supertype?.element3;
    }
  }

  Iterable<PropertyAccessorElement2OrMember> _implementationsOfSetter2(
    String name,
  ) sync* {
    var visitedElements = <InstanceElement>{};
    InstanceElement? element = this;
    while (element != null && visitedElements.add(element)) {
      var setter = element.getSetter(name);
      if (setter != null) {
        yield setter as PropertyAccessorElement2OrMember;
      }
      if (element is! InterfaceElement) {
        return;
      }
      for (var mixin in element.mixins.reversed) {
        mixin as InterfaceTypeImpl;
        setter = mixin.element3.getSetter(name);
        if (setter != null) {
          yield setter as PropertyAccessorElement2OrMember;
        }
      }
      var supertype = element.firstFragment.supertype;
      supertype as InterfaceTypeImpl?;
      element = supertype?.element3;
    }
  }
}

abstract class InstanceFragmentImpl extends _ExistingFragmentImpl
    with
        AugmentableFragment,
        DeferredMembersReadingMixin,
        DeferredResolutionReadingMixin,
        TypeParameterizedFragmentMixin
    implements InstanceFragment {
  void Function()? applyMembersConstantOffsets;

  @override
  final String? name2;

  @override
  int? nameOffset2;

  @override
  InstanceFragmentImpl? previousFragment;

  @override
  InstanceFragmentImpl? nextFragment;

  List<FieldFragmentImpl> _fields = _Sentinel.fieldElement;
  List<GetterFragmentImpl> _getters = _Sentinel.getterElement;
  List<SetterFragmentImpl> _setters = _Sentinel.setterElement;
  List<MethodFragmentImpl> _methods = _Sentinel.methodElement;

  InstanceFragmentImpl({required this.name2, required super.nameOffset});

  List<PropertyAccessorFragmentImpl> get accessors {
    return [...getters, ...setters];
  }

  @override
  InstanceElementImpl get element;

  @override
  LibraryFragmentImpl get enclosingElement3 {
    return super.enclosingElement3 as LibraryFragmentImpl;
  }

  @override
  LibraryFragment? get enclosingFragment => enclosingElement3;

  @override
  List<FieldFragmentImpl> get fields {
    if (!identical(_fields, _Sentinel.fieldElement)) {
      return _fields;
    }

    element.ensureReadMembers();
    _ensureReadResolution();
    return _fields;
  }

  set fields(List<FieldFragmentImpl> fields) {
    for (var field in fields) {
      field.enclosingElement3 = this;
    }
    _fields = fields;
  }

  @Deprecated('Use fields instead')
  @override
  List<FieldFragment> get fields2 => fields.cast<FieldFragment>();

  @override
  List<GetterFragmentImpl> get getters {
    if (!identical(_getters, _Sentinel.getterElement)) {
      return _getters;
    }

    element.ensureReadMembers();
    _ensureReadResolution();
    return _getters;
  }

  set getters(List<GetterFragmentImpl> getters) {
    for (var getter in getters) {
      getter.enclosingElement3 = this;
    }
    _getters = getters;
  }

  @override
  MetadataImpl get metadata {
    _ensureReadResolution();
    return super.metadata;
  }

  @override
  List<MethodFragmentImpl> get methods {
    if (!identical(_methods, _Sentinel.methodElement)) {
      return _methods;
    }

    element.ensureReadMembers();
    _ensureReadResolution();
    return _methods;
  }

  set methods(List<MethodFragmentImpl> methods) {
    for (var method in methods) {
      method.enclosingElement3 = this;
    }
    _methods = methods;
  }

  @Deprecated('Use methods instead')
  @override
  List<MethodFragment> get methods2 => methods.cast<MethodFragment>();

  @override
  int get offset => _nameOffset;

  @override
  List<SetterFragmentImpl> get setters {
    if (!identical(_setters, _Sentinel.setterElement)) {
      return _setters;
    }

    element.ensureReadMembers();
    _ensureReadResolution();
    return _setters;
  }

  set setters(List<SetterFragmentImpl> setters) {
    for (var setter in setters) {
      setter.enclosingElement3 = this;
    }
    _setters = setters;
  }

  void addField(FieldFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _fields = [..._fields, fragment];
    fragment.enclosingElement3 = this;
  }

  void addGetter(GetterFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _getters = [..._getters, fragment];
    fragment.enclosingElement3 = this;
  }

  void addMethod(MethodFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _methods = [..._methods, fragment];
    fragment.enclosingElement3 = this;
  }

  void addSetter(SetterFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _setters = [..._setters, fragment];
    fragment.enclosingElement3 = this;
  }
}

abstract class InterfaceElementImpl extends InstanceElementImpl
    with _HasSinceSdkVersionMixin
    implements InterfaceElement {
  /// The non-nullable instance of this element, without alias.
  /// Should be used only when the element has no type parameters.
  InterfaceTypeImpl? _nonNullableInstance;

  /// The nullable instance of this element, without alias.
  /// Should be used only when the element has no type parameters.
  InterfaceTypeImpl? _nullableInstance;

  InterfaceTypeImpl? _thisType;

  /// The cached result of [allSupertypes].
  List<InterfaceTypeImpl>? _allSupertypes;

  List<ConstructorElementImpl> _constructors = [];

  @override
  List<InterfaceTypeImpl> get allSupertypes {
    return _allSupertypes ??= library2.session.classHierarchy
        .implementedInterfaces(this);
  }

  @override
  List<Element> get children2 {
    return [...super.children2, ...constructors];
  }

  @override
  List<ConstructorElementImpl> get constructors {
    ensureReadMembers();
    // TODO(scheglov): we use this for the side effect of creating
    firstFragment.constructors;
    return _constructors;
  }

  set constructors(List<ConstructorElementImpl> value) {
    _constructors = value;
  }

  @Deprecated('Use constructors instead')
  @override
  List<ConstructorElementImpl> get constructors2 {
    return constructors;
  }

  @override
  InterfaceFragmentImpl get firstFragment;

  @override
  List<InterfaceFragmentImpl> get fragments {
    return [
      for (
        InterfaceFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  InheritanceManager3 get inheritanceManager {
    return library2.session.inheritanceManager;
  }

  @override
  Map<Name, ExecutableElement> get inheritedConcreteMembers =>
      (session as AnalysisSessionImpl).inheritanceManager
          .getInheritedConcreteMap(this);

  @override
  Map<Name, ExecutableElement> get inheritedMembers =>
      (session as AnalysisSessionImpl).inheritanceManager.getInheritedMap(this);

  @override
  Map<Name, ExecutableElement> get interfaceMembers =>
      (session as AnalysisSessionImpl).inheritanceManager
          .getInterface(this)
          .map2;

  @override
  List<InterfaceTypeImpl> get interfaces {
    return firstFragment.interfaces;
  }

  set isSimplyBounded(bool value) {
    for (var fragment in fragments) {
      fragment.isSimplyBounded = value;
    }
  }

  @override
  List<InterfaceTypeImpl> get mixins {
    return firstFragment.mixins;
  }

  @override
  InterfaceTypeImpl? get supertype => firstFragment.supertype;

  @override
  InterfaceTypeImpl get thisType {
    if (_thisType == null) {
      List<TypeImpl> typeArguments;
      var typeParameters = firstFragment.typeParameters;
      if (typeParameters.isNotEmpty) {
        typeArguments =
            typeParameters.map<TypeImpl>((t) {
              return t.instantiate(nullabilitySuffix: NullabilitySuffix.none);
            }).toFixedList();
      } else {
        typeArguments = const [];
      }
      return _thisType = instantiateImpl(
        typeArguments: typeArguments,
        nullabilitySuffix: NullabilitySuffix.none,
      );
    }
    return _thisType!;
  }

  @override
  ConstructorElementImpl? get unnamedConstructor2 {
    return getNamedConstructor2('new');
  }

  void addConstructor(ConstructorElementImpl element) {
    _constructors.add(element);
  }

  @override
  ExecutableElement? getInheritedConcreteMember(Name name) =>
      inheritedConcreteMembers[name];

  @override
  ExecutableElement? getInheritedMember(Name name) =>
      (session as AnalysisSessionImpl).inheritanceManager.getInherited(
        this,
        name,
      );

  @override
  ExecutableElement? getInterfaceMember(Name name) =>
      (session as AnalysisSessionImpl).inheritanceManager.getMember(this, name);

  @override
  ConstructorElementImpl? getNamedConstructor2(String name) {
    globalResultRequirements?.record_interfaceElement_getNamedConstructor(
      element: this,
      name: name,
    );
    return constructors.firstWhereOrNull((e) => e.name3 == name);
  }

  @override
  List<ExecutableElement>? getOverridden(Name name) =>
      (session as AnalysisSessionImpl).inheritanceManager.getOverridden4(
        this,
        name,
      );

  @override
  InterfaceTypeImpl instantiate({
    required List<DartType> typeArguments,
    required NullabilitySuffix nullabilitySuffix,
  }) {
    return instantiateImpl(
      typeArguments: typeArguments.cast<TypeImpl>(),
      nullabilitySuffix: nullabilitySuffix,
    );
  }

  InterfaceTypeImpl instantiateImpl({
    required List<TypeImpl> typeArguments,
    required NullabilitySuffix nullabilitySuffix,
  }) {
    assert(typeArguments.length == typeParameters2.length);

    if (typeArguments.isEmpty) {
      switch (nullabilitySuffix) {
        case NullabilitySuffix.none:
          if (_nonNullableInstance case var instance?) {
            return instance;
          }
        case NullabilitySuffix.question:
          if (_nullableInstance case var instance?) {
            return instance;
          }
        case NullabilitySuffix.star:
          // TODO(scheglov): remove together with `star`
          break;
      }
    }

    var result = InterfaceTypeImpl(
      element: this,
      typeArguments: typeArguments,
      nullabilitySuffix: nullabilitySuffix,
    );

    if (typeArguments.isEmpty) {
      switch (nullabilitySuffix) {
        case NullabilitySuffix.none:
          _nonNullableInstance = result;
        case NullabilitySuffix.question:
          _nullableInstance = result;
        case NullabilitySuffix.star:
          // TODO(scheglov): remove together with `star`
          break;
      }
    }

    return result;
  }

  @override
  MethodElement? lookUpConcreteMethod(
    String methodName,
    LibraryElement library,
  ) {
    return _implementationsOfMethod2(methodName).firstWhereOrNull(
      (method) => !method.isAbstract && method.isAccessibleIn2(library),
    );
  }

  PropertyAccessorElement? lookUpInheritedConcreteGetter(
    String getterName,
    LibraryElement library,
  ) {
    return _implementationsOfGetter2(getterName).firstWhereOrNull(
      (getter) =>
          !getter.isAbstract &&
          !getter.isStatic &&
          getter.isAccessibleIn2(library) &&
          getter.enclosingElement != this,
    );
  }

  MethodElement? lookUpInheritedConcreteMethod(
    String methodName,
    LibraryElement library,
  ) {
    return _implementationsOfMethod2(methodName).firstWhereOrNull(
      (method) =>
          !method.isAbstract &&
          !method.isStatic &&
          method.isAccessibleIn2(library) &&
          method.enclosingElement != this,
    );
  }

  PropertyAccessorElement? lookUpInheritedConcreteSetter(
    String setterName,
    LibraryElement library,
  ) {
    return _implementationsOfSetter2(setterName).firstWhereOrNull(
      (setter) =>
          !setter.isAbstract &&
          !setter.isStatic &&
          setter.isAccessibleIn2(library) &&
          setter.enclosingElement != this,
    );
  }

  MethodElement? lookUpInheritedMethod(
    String methodName,
    LibraryElement library,
  ) {
    return _implementationsOfMethod2(methodName).firstWhereOrNull(
      (method) =>
          !method.isStatic &&
          method.isAccessibleIn2(library) &&
          method.enclosingElement != this,
    );
  }

  @override
  MethodElement? lookUpInheritedMethod2({
    required String methodName,
    required LibraryElement library,
  }) {
    return inheritanceManager
        .getInherited(this, Name.forLibrary(library, methodName))
        .ifTypeOrNull();
  }

  /// Return the static getter with the [name], accessible to the [library].
  ///
  /// This method should be used only for error recovery during analysis,
  /// when instance access to a static class member, defined in this class,
  /// or a superclass.
  GetterElement2OrMember? lookupStaticGetter(
    String name,
    LibraryElement library,
  ) {
    return _implementationsOfGetter2(name)
        .firstWhereOrNull(
          (element) => element.isStatic && element.isAccessibleIn2(library),
        )
        .ifTypeOrNull();
  }

  /// Return the static method with the [name], accessible to the [library].
  ///
  /// This method should be used only for error recovery during analysis,
  /// when instance access to a static class member, defined in this class,
  /// or a superclass.
  MethodElement2OrMember? lookupStaticMethod(
    String name,
    LibraryElement library,
  ) {
    return _implementationsOfMethod2(name).firstWhereOrNull(
      (element) => element.isStatic && element.isAccessibleIn2(library),
    );
  }

  /// Return the static setter with the [name], accessible to the [library].
  ///
  /// This method should be used only for error recovery during analysis,
  /// when instance access to a static class member, defined in this class,
  /// or a superclass.
  SetterElement2OrMember? lookupStaticSetter(
    String name,
    LibraryElement library,
  ) {
    return _implementationsOfSetter2(name)
        .firstWhereOrNull(
          (element) => element.isStatic && element.isAccessibleIn2(library),
        )
        .ifTypeOrNull();
  }

  void resetCachedAllSupertypes() {
    _allSupertypes = null;
  }
}

abstract class InterfaceFragmentImpl extends InstanceFragmentImpl
    implements InterfaceFragment {
  /// A list containing all of the mixins that are applied to the class being
  /// extended in order to derive the superclass of this class.
  List<InterfaceTypeImpl> _mixins = const [];

  /// A list containing all of the interfaces that are implemented by this
  /// class.
  List<InterfaceTypeImpl> _interfaces = const [];

  /// This callback is set during mixins inference to handle reentrant calls.
  List<InterfaceType>? Function(InterfaceFragmentImpl)? mixinInferenceCallback;

  InterfaceTypeImpl? _supertype;

  /// A flag indicating whether the types associated with the instance members
  /// of this class have been inferred.
  bool hasBeenInferred = false;

  List<ConstructorFragmentImpl> _constructors = _Sentinel.constructorElement;

  /// Initialize a newly created class element to have the given [name] at the
  /// given [offset] in the file that contains the declaration of this element.
  InterfaceFragmentImpl({required super.name2, required super.nameOffset});

  @override
  List<Fragment> get children3 => [
    ...constructors,
    ...fields,
    ...getters,
    ...methods,
    ...setters,
    ...typeParameters,
  ];

  @override
  List<ConstructorFragmentImpl> get constructors {
    element.ensureReadMembers();
    if (!identical(_constructors, _Sentinel.constructorElement)) {
      return _constructors;
    }

    _buildMixinAppConstructors();
    return _constructors;
  }

  set constructors(List<ConstructorFragmentImpl> constructors) {
    for (var constructor in constructors) {
      constructor.enclosingElement3 = this;
    }
    _constructors = constructors;
  }

  @Deprecated('Use constructors instead')
  @override
  List<ConstructorFragmentImpl> get constructors2 {
    return constructors;
  }

  @override
  String get displayName => name2 ?? '';

  @override
  InterfaceElementImpl get element;

  @override
  List<InterfaceTypeImpl> get interfaces {
    _ensureReadResolution();
    return _interfaces;
  }

  set interfaces(List<InterfaceType> interfaces) {
    // TODO(paulberry): eliminate this cast by changing the type of the
    // `interfaces` parameter.
    _interfaces = interfaces.cast();
  }

  /// Return `true` if this class represents the class '_Enum' defined in the
  /// dart:core library.
  bool get isDartCoreEnumImpl {
    return name2 == '_Enum' && library.isDartCore;
  }

  /// Return `true` if this class represents the class 'Function' defined in the
  /// dart:core library.
  bool get isDartCoreFunctionImpl {
    return name2 == 'Function' && library.isDartCore;
  }

  @override
  bool get isSimplyBounded {
    return hasModifier(Modifier.SIMPLY_BOUNDED);
  }

  set isSimplyBounded(bool isSimplyBounded) {
    setModifier(Modifier.SIMPLY_BOUNDED, isSimplyBounded);
  }

  @override
  List<InterfaceTypeImpl> get mixins {
    if (mixinInferenceCallback != null) {
      var mixins = mixinInferenceCallback!(this);
      if (mixins != null) {
        // TODO(paulberry): eliminate this cast by changing the type of
        // `InterfaceElementImpl.mixinInferenceCallback`.
        return _mixins = mixins.cast();
      }
    }

    _ensureReadResolution();
    return _mixins;
  }

  set mixins(List<InterfaceType> mixins) {
    // TODO(paulberry): eliminate this cast by changing the type of the `mixins`
    // parameter.
    _mixins = mixins.cast();
  }

  @override
  InterfaceFragmentImpl? get nextFragment {
    return super.nextFragment as InterfaceFragmentImpl?;
  }

  @override
  InterfaceFragmentImpl? get previousFragment {
    return super.previousFragment as InterfaceFragmentImpl?;
  }

  @override
  InterfaceTypeImpl? get supertype {
    _ensureReadResolution();
    return _supertype;
  }

  set supertype(InterfaceType? value) {
    // TODO(paulberry): eliminate this cast by changing the type of the `value`
    // parameter.
    _supertype = value as InterfaceTypeImpl?;
  }

  void addConstructor(ConstructorFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _constructors = [..._constructors, fragment];
    fragment.enclosingElement3 = this;
  }

  /// Builds constructors for this mixin application.
  void _buildMixinAppConstructors() {}

  static PropertyAccessorElementOrMember? getSetterFromAccessors(
    String setterName,
    List<PropertyAccessorElementOrMember> accessors,
  ) {
    return accessors.firstWhereOrNull(
      (accessor) => accessor.isSetter && accessor.name2 == setterName,
    );
  }
}

class JoinPatternVariableElementImpl extends PatternVariableElementImpl
    implements JoinPatternVariableElement {
  JoinPatternVariableElementImpl(super._wrappedElement);

  @override
  JoinPatternVariableFragmentImpl get firstFragment =>
      super.firstFragment as JoinPatternVariableFragmentImpl;

  @override
  List<JoinPatternVariableFragmentImpl> get fragments {
    return [
      for (
        JoinPatternVariableFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  shared.JoinedPatternVariableInconsistency get inconsistency =>
      _wrappedElement.inconsistency;

  set inconsistency(shared.JoinedPatternVariableInconsistency value) =>
      _wrappedElement.inconsistency = value;

  @override
  bool get isConsistent => _wrappedElement.isConsistent;

  set isFinal(bool value) => _wrappedElement.isFinal = value;

  /// The identifiers that reference this element.
  List<SimpleIdentifier> get references => _wrappedElement.references;

  /// Returns this variable, and variables that join into it.
  List<PatternVariableElementImpl> get transitiveVariables {
    var result = <PatternVariableElementImpl>[];

    void append(PatternVariableElementImpl variable) {
      result.add(variable);
      if (variable is JoinPatternVariableElementImpl) {
        for (var variable in variable.variables) {
          append(variable);
        }
      }
    }

    append(this);
    return result;
  }

  @override
  List<PatternVariableElementImpl> get variables =>
      _wrappedElement.variables.map((fragment) => fragment.element).toList();

  /// The variables that join into this variable.
  @Deprecated('Use variables instead')
  @override
  List<PatternVariableElementImpl> get variables2 {
    return variables;
  }

  @override
  JoinPatternVariableFragmentImpl get _wrappedElement =>
      super._wrappedElement as JoinPatternVariableFragmentImpl;
}

class JoinPatternVariableFragmentImpl extends PatternVariableFragmentImpl
    implements JoinPatternVariableFragment {
  /// The variables that join into this variable.
  final List<PatternVariableFragmentImpl> variables;

  shared.JoinedPatternVariableInconsistency inconsistency;

  /// The identifiers that reference this element.
  final List<SimpleIdentifier> references = [];

  JoinPatternVariableFragmentImpl({
    required super.name2,
    required super.nameOffset,
    required this.variables,
    required this.inconsistency,
  }) {
    for (var component in variables) {
      component.join = this;
    }
  }

  @override
  JoinPatternVariableElementImpl get element =>
      super.element as JoinPatternVariableElementImpl;

  @override
  bool get isConsistent {
    return inconsistency == shared.JoinedPatternVariableInconsistency.none;
  }

  @override
  JoinPatternVariableFragmentImpl? get nextFragment =>
      super.nextFragment as JoinPatternVariableFragmentImpl?;

  @override
  int get offset => variables[0].offset;

  @override
  JoinPatternVariableFragmentImpl? get previousFragment =>
      super.previousFragment as JoinPatternVariableFragmentImpl?;

  /// Returns this variable, and variables that join into it.
  List<PatternVariableFragmentImpl> get transitiveVariables {
    var result = <PatternVariableFragmentImpl>[];

    void append(PatternVariableFragmentImpl variable) {
      result.add(variable);
      if (variable is JoinPatternVariableFragmentImpl) {
        for (var variable in variable.variables) {
          append(variable);
        }
      }
    }

    append(this);
    return result;
  }

  @override
  List<PatternVariableFragment> get variables2 =>
      variables.cast<PatternVariableFragment>();
}

class LabelElementImpl extends ElementImpl
    with WrappedElementMixin
    implements LabelElement {
  @override
  final LabelFragmentImpl _wrappedElement;

  LabelElementImpl(this._wrappedElement);

  @override
  LabelElement get baseElement => this;

  @override
  ExecutableElement? get enclosingElement => null;

  @Deprecated('Use enclosingElement instead')
  @override
  ExecutableElement? get enclosingElement2 => enclosingElement;

  @override
  LabelFragmentImpl get firstFragment => _wrappedElement;

  @override
  List<LabelFragmentImpl> get fragments {
    return [firstFragment];
  }

  /// Return `true` if this label is associated with a `switch` member (`case`
  /// or `default`).
  bool get isOnSwitchMember => _wrappedElement.isOnSwitchMember;

  @override
  LibraryElement get library2 {
    return _wrappedElement.library;
  }

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitLabelElement(this);
  }

  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {}
}

class LabelFragmentImpl extends FragmentImpl implements LabelFragment {
  late final LabelElementImpl element2 = LabelElementImpl(this);

  @override
  final String? name2;

  /// A flag indicating whether this label is associated with a `switch` member
  /// (`case` or `default`).
  // TODO(brianwilkerson): Make this a modifier.
  final bool _onSwitchMember;

  /// Initialize a newly created label element to have the given [name].
  /// [_onSwitchMember] should be `true` if this label is associated with a
  /// `switch` member.
  LabelFragmentImpl({
    required this.name2,
    required super.nameOffset,
    required bool onSwitchMember,
  }) : _onSwitchMember = onSwitchMember;

  @override
  List<Fragment> get children3 => const [];

  @override
  String get displayName => name2 ?? '';

  @override
  LabelElement get element => element2;

  @override
  ExecutableFragmentImpl get enclosingElement3 =>
      super.enclosingElement3 as ExecutableFragmentImpl;

  @override
  ExecutableFragment get enclosingFragment =>
      enclosingElement3 as ExecutableFragment;

  /// Return `true` if this label is associated with a `switch` member (`case`
  /// or `default`).
  bool get isOnSwitchMember => _onSwitchMember;

  @override
  ElementKind get kind => ElementKind.LABEL;

  @override
  LibraryElementImpl get library {
    return libraryFragment.element;
  }

  @override
  LibraryFragmentImpl get libraryFragment => enclosingUnit;

  @override
  // TODO(scheglov): make it a nullable field
  int? get nameOffset2 => nameOffset;

  @override
  LabelFragmentImpl? get nextFragment => null;

  @override
  int get offset => _nameOffset;

  @override
  LabelFragmentImpl? get previousFragment => null;
}

/// A concrete implementation of [LibraryElement].
class LibraryElementImpl extends ElementImpl
    with DeferredResolutionReadingMixin
    implements LibraryElement {
  final AnalysisContext context;

  @override
  Reference? reference;

  MetadataImpl _metadata = MetadataImpl(const []);

  @override
  String? documentationComment;

  @override
  AnalysisSessionImpl session;

  /// The compilation unit that defines this library.
  late LibraryFragmentImpl definingCompilationUnit;

  /// The language version for the library.
  LibraryLanguageVersion? _languageVersion;

  bool hasTypeProviderSystemSet = false;

  @override
  late TypeProviderImpl typeProvider;

  @override
  late TypeSystemImpl typeSystem;

  late List<ExportedReference> exportedReferences;

  /// The union of names for all searchable elements in this library.
  ElementNameUnion nameUnion = ElementNameUnion.empty();

  @override
  final FeatureSet featureSet;

  /// The entry point for this library, or `null` if this library does not have
  /// an entry point.
  TopLevelFunctionElementImpl? _entryPoint;

  /// The provider for the synthetic function `loadLibrary` that is defined
  /// for this library.
  late final LoadLibraryFunctionProvider loadLibraryProvider;

  // TODO(scheglov): replace with `LibraryName` or something.
  String name;

  // TODO(scheglov): replace with `LibraryName` or something.
  int nameOffset;

  // TODO(scheglov): replace with `LibraryName` or something.
  int nameLength;

  @override
  bool isSynthetic = false;

  @override
  List<ClassElementImpl> classes = [];

  @override
  List<EnumElementImpl> enums = [];

  @override
  List<ExtensionElementImpl> extensions = [];

  @override
  List<ExtensionTypeElementImpl> extensionTypes = [];

  @override
  List<GetterElementImpl> getters = [];

  @override
  List<SetterElementImpl> setters = [];

  @override
  List<MixinElementImpl> mixins = [];

  @override
  List<TopLevelFunctionElementImpl> topLevelFunctions = [];

  @override
  List<TopLevelVariableElementImpl> topLevelVariables = [];

  @override
  List<TypeAliasElementImpl> typeAliases = [];

  /// The export [Namespace] of this library, `null` if it has not been
  /// computed yet.
  Namespace? _exportNamespace;

  /// The public [Namespace] of this library, `null` if it has not been
  /// computed yet.
  Namespace? _publicNamespace;

  /// Information about why non-promotable private fields in the library are not
  /// promotable.
  ///
  /// See [fieldNameNonPromotabilityInfo].
  Map<String, FieldNameNonPromotabilityInfo>? _fieldNameNonPromotabilityInfo;

  /// The map of top-level declarations, from all units.
  LibraryDeclarations? _libraryDeclarations;

  /// If [withFineDependencies] is `true`, the manifest of the library.
  LibraryManifest? manifest;

  /// Initialize a newly created library element in the given [context] to have
  /// the given [name] and [offset].
  LibraryElementImpl(
    this.context,
    this.session,
    this.name,
    this.nameOffset,
    this.nameLength,
    this.featureSet,
  );

  @override
  LibraryElementImpl get baseElement => this;

  @override
  List<Element> get children2 {
    return [
      ...classes,
      ...enums,
      ...extensions,
      ...extensionTypes,
      ...getters,
      ...mixins,
      ...setters,
      ...topLevelFunctions,
      ...topLevelVariables,
      ...typeAliases,
    ];
  }

  @override
  Null get enclosingElement => null;

  @Deprecated('Use enclosingElement instead')
  @override
  Null get enclosingElement2 => enclosingElement;

  @override
  TopLevelFunctionElementImpl? get entryPoint2 {
    _ensureReadResolution();
    return _entryPoint;
  }

  set entryPoint2(TopLevelFunctionElementImpl? value) {
    _entryPoint = value;
  }

  @override
  List<LibraryElementImpl> get exportedLibraries2 {
    return fragments
        .expand((fragment) => fragment.libraryExports)
        .map((export) => export.exportedLibrary2)
        .nonNulls
        .toSet()
        .toList();
  }

  @override
  Namespace get exportNamespace {
    _ensureReadResolution();
    return _exportNamespace ??= Namespace({});
  }

  set exportNamespace(Namespace exportNamespace) {
    _exportNamespace = exportNamespace;
  }

  /// Information about why non-promotable private fields in the library are not
  /// promotable.
  ///
  /// If field promotion is not enabled in this library, this field is still
  /// populated, so that the analyzer can figure out whether enabling field
  /// promotion would cause a field to be promotable.
  ///
  /// There are two ways an access to a private property name might not be
  /// promotable: the property might be non-promotable for a reason inherent to
  /// itself (e.g. it's declared as a concrete getter rather than a field, or
  /// it's a non-final field), or the property might have the same name as an
  /// inherently non-promotable property elsewhere in the same library (in which
  /// case the inherently non-promotable property is said to be "conflicting").
  ///
  /// When a compile-time error occurs because a property is non-promotable due
  /// conflicting properties elsewhere in the library, the analyzer needs to be
  /// able to find the conflicting properties in order to generate context
  /// messages. This data structure allows that, by mapping each non-promotable
  /// private name to the set of conflicting declarations.
  ///
  /// If a field in the library has a private name and that name does not appear
  /// as a key in this map, the field is promotable.
  Map<String, FieldNameNonPromotabilityInfo> get fieldNameNonPromotabilityInfo {
    _ensureReadResolution();
    return _fieldNameNonPromotabilityInfo!;
  }

  set fieldNameNonPromotabilityInfo(
    Map<String, FieldNameNonPromotabilityInfo>? value,
  ) {
    _fieldNameNonPromotabilityInfo = value;
  }

  @override
  LibraryFragmentImpl get firstFragment => definingCompilationUnit;

  @override
  List<LibraryFragmentImpl> get fragments {
    return [definingCompilationUnit, ..._partUnits];
  }

  bool get hasPartOfDirective {
    return hasModifier(Modifier.HAS_PART_OF_DIRECTIVE);
  }

  set hasPartOfDirective(bool hasPartOfDirective) {
    setModifier(Modifier.HAS_PART_OF_DIRECTIVE, hasPartOfDirective);
  }

  @override
  String get identifier => '${definingCompilationUnit.source.uri}';

  @override
  bool get isDartAsync => name == "dart.async";

  @override
  bool get isDartCore => name == "dart.core";

  @override
  bool get isInSdk {
    var uri = definingCompilationUnit.source.uri;
    return DartUriResolver.isDartUri(uri);
  }

  @override
  ElementKind get kind => ElementKind.LIBRARY;

  @override
  LibraryLanguageVersion get languageVersion {
    return _languageVersion ??= LibraryLanguageVersion(
      package: ExperimentStatus.currentVersion,
      override: null,
    );
  }

  set languageVersion(LibraryLanguageVersion languageVersion) {
    _languageVersion = languageVersion;
  }

  @override
  LibraryElementImpl get library2 => this;

  LibraryDeclarations get libraryDeclarations {
    return _libraryDeclarations ??= LibraryDeclarations(this);
  }

  @override
  TopLevelFunctionElementImpl get loadLibraryFunction2 {
    return loadLibraryProvider.getElement(this);
  }

  @override
  String? get lookupName => null;

  @override
  MetadataImpl get metadata {
    _ensureReadResolution();
    return _metadata;
  }

  set metadata(MetadataImpl value) {
    _metadata = value;
  }

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  String? get name3 => name;

  @override
  LibraryElementImpl get nonSynthetic => this;

  @override
  Namespace get publicNamespace {
    return _publicNamespace ??= NamespaceBuilder()
        .createPublicNamespaceForLibrary(this);
  }

  set publicNamespace(Namespace publicNamespace) {
    _publicNamespace = publicNamespace;
  }

  @override
  Version? get sinceSdkVersion {
    return SinceSdkVersionComputer().compute(this);
  }

  // TODO(scheglov): replace with `firstFragment.source`
  Source get source {
    return definingCompilationUnit.source;
  }

  Iterable<FragmentImpl> get topLevelElements sync* {
    for (var unit in units) {
      yield* unit.accessors;
      yield* unit.classes;
      yield* unit.enums;
      yield* unit.extensions;
      yield* unit.extensionTypes;
      yield* unit.functions;
      yield* unit.mixins;
      yield* unit.topLevelVariables;
      yield* unit.typeAliases;
    }
  }

  /// The compilation units this library consists of.
  ///
  /// This includes the defining compilation unit and units included using the
  /// `part` directive.
  List<LibraryFragmentImpl> get units {
    return [definingCompilationUnit, ..._partUnits];
  }

  @override
  Uri get uri => firstFragment.source.uri;

  List<LibraryFragmentImpl> get _partUnits {
    var result = <LibraryFragmentImpl>[];

    void visitParts(LibraryFragmentImpl unit) {
      for (var part in unit.parts) {
        if (part.uri case DirectiveUriWithUnitImpl uri) {
          var unit = uri.libraryFragment;
          result.add(unit);
          visitParts(unit);
        }
      }
    }

    visitParts(definingCompilationUnit);
    return result;
  }

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitLibraryElement(this);
  }

  void addClass(ClassElementImpl element) {
    classes.add(element);
  }

  void addEnum(EnumElementImpl element) {
    enums.add(element);
  }

  void addExtension(ExtensionElementImpl element) {
    extensions.add(element);
  }

  void addExtensionType(ExtensionTypeElementImpl element) {
    extensionTypes.add(element);
  }

  void addGetter(GetterElementImpl element) {
    getters.add(element);
  }

  void addMixin(MixinElementImpl element) {
    mixins.add(element);
  }

  void addSetter(SetterElementImpl element) {
    setters.add(element);
  }

  void addTopLevelFunction(TopLevelFunctionElementImpl element) {
    topLevelFunctions.add(element);
  }

  void addTopLevelVariable(TopLevelVariableElementImpl element) {
    topLevelVariables.add(element);
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeLibraryElement(this);
  }

  @override
  String displayString2({
    bool multiline = false,
    bool preferTypeAlias = false,
  }) {
    var builder = ElementDisplayStringBuilder(
      multiline: multiline,
      preferTypeAlias: preferTypeAlias,
    );
    appendTo(builder);
    return builder.toString();
  }

  @override
  ClassElementImpl? getClass2(String name) {
    return _getElementByName(classes, name);
  }

  @override
  EnumElement? getEnum2(String name) {
    return _getElementByName(enums, name);
  }

  @override
  String getExtendedDisplayName2({String? shortName}) {
    shortName ??= displayName;
    var source = this.source;
    return "$shortName (${source.fullName})";
  }

  @override
  ExtensionElement? getExtension(String name) {
    return _getElementByName(extensions, name);
  }

  @override
  ExtensionTypeElementImpl? getExtensionType(String name) {
    return _getElementByName(extensionTypes, name);
  }

  @override
  GetterElement? getGetter(String name) {
    return _getElementByName(getters, name);
  }

  @override
  MixinElement? getMixin2(String name) {
    return _getElementByName(mixins, name);
  }

  @override
  SetterElement? getSetter(String name) {
    return _getElementByName(setters, name);
  }

  @override
  TopLevelFunctionElement? getTopLevelFunction(String name) {
    return _getElementByName(topLevelFunctions, name);
  }

  @override
  TopLevelVariableElement? getTopLevelVariable(String name) {
    return _getElementByName(topLevelVariables, name);
  }

  @override
  TypeAliasElement? getTypeAlias(String name) {
    return _getElementByName(typeAliases, name);
  }

  @override
  bool isAccessibleIn2(LibraryElement library) {
    return true;
  }

  /// Return `true` if [reference] comes only from deprecated exports.
  bool isFromDeprecatedExport(ExportedReference reference) {
    if (reference is ExportedReferenceExported) {
      for (var location in reference.locations) {
        var export = location.exportOf(this);
        if (!export.metadata.hasDeprecated) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  void resetScope() {
    _libraryDeclarations = null;
    for (var fragment in units) {
      fragment._scope = null;
    }
  }

  @override
  LibraryElementImpl? thisOrAncestorMatching2(
    bool Function(Element) predicate,
  ) {
    return predicate(this) ? this : null;
  }

  @override
  E? thisOrAncestorOfType2<E extends Element>() {
    return E is LibraryElement ? this as E : null;
  }

  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {
    for (var child in children2) {
      child.accept2(visitor);
    }
  }

  static T? _getElementByName<T extends Element>(
    List<T> elements,
    String name,
  ) {
    return elements.firstWhereOrNull((e) => e.name3 == name);
  }
}

class LibraryExportImpl extends ElementDirectiveImpl implements LibraryExport {
  @override
  final List<NamespaceCombinator> combinators;

  @override
  int exportKeywordOffset;

  LibraryExportImpl({
    required super.uri,
    required this.combinators,
    required this.exportKeywordOffset,
  });

  @override
  LibraryElementImpl? get exportedLibrary2 {
    if (uri case DirectiveUriWithLibraryImpl uri) {
      return uri.library2;
    }
    return null;
  }
}

/// A concrete implementation of [LibraryFragment].
class LibraryFragmentImpl extends _ExistingFragmentImpl
    with DeferredResolutionReadingMixin
    implements LibraryFragment {
  /// The source that corresponds to this compilation unit.
  @override
  final Source source;

  @override
  LineInfo lineInfo;

  @override
  final LibraryElementImpl library;

  /// The libraries exported by this unit.
  List<LibraryExportImpl> _libraryExports = _Sentinel.libraryExport;

  /// The libraries imported by this unit.
  List<LibraryImportImpl> _libraryImports = _Sentinel.libraryImport;

  /// The cached list of prefixes from [prefixes].
  List<PrefixElementImpl>? _libraryImportPrefixes2;

  /// The parts included by this unit.
  List<PartIncludeImpl> _parts = const <PartIncludeImpl>[];

  /// All top-level getters in this compilation unit.
  List<GetterFragmentImpl> _getters = _Sentinel.getterElement;

  /// All top-level setters in this compilation unit.
  List<SetterFragmentImpl> _setters = _Sentinel.setterElement;

  List<ClassFragmentImpl> _classes = const [];

  /// A list containing all of the enums contained in this compilation unit.
  List<EnumFragmentImpl> _enums = const [];

  /// A list containing all of the extensions contained in this compilation
  /// unit.
  List<ExtensionFragmentImpl> _extensions = const [];

  List<ExtensionTypeFragmentImpl> _extensionTypes = const [];

  /// A list containing all of the top-level functions contained in this
  /// compilation unit.
  List<TopLevelFunctionFragmentImpl> _functions = const [];

  List<MixinFragmentImpl> _mixins = const [];

  /// A list containing all of the type aliases contained in this compilation
  /// unit.
  List<TypeAliasFragmentImpl> _typeAliases = const [];

  /// A list containing all of the variables contained in this compilation unit.
  List<TopLevelVariableFragmentImpl> _variables = const [];

  /// The scope of this fragment, `null` if it has not been created yet.
  LibraryFragmentScope? _scope;

  LibraryFragmentImpl({
    required this.library,
    required this.source,
    required this.lineInfo,
  }) : super(nameOffset: -1);

  @override
  List<ExtensionElement> get accessibleExtensions2 {
    return scope.accessibleExtensions;
  }

  List<PropertyAccessorFragmentImpl> get accessors {
    return [...getters, ...setters];
  }

  @override
  List<Fragment> get children3 {
    return [
      ...classes,
      ...enums,
      ...extensions,
      ...extensionTypes,
      ...functions,
      ...getters,
      ...mixins,
      ...setters,
      ...typeAliases,
      ...topLevelVariables,
    ];
  }

  List<ClassFragmentImpl> get classes {
    return _classes;
  }

  /// Set the classes contained in this compilation unit to [classes].
  set classes(List<ClassFragmentImpl> classes) {
    for (var class_ in classes) {
      class_.enclosingElement3 = this;
    }
    _classes = classes;
  }

  @override
  List<ClassFragmentImpl> get classes2 => classes;

  @override
  LibraryElementImpl get element => library;

  @override
  LibraryFragmentImpl? get enclosingElement3 {
    return super.enclosingElement3 as LibraryFragmentImpl?;
  }

  @override
  LibraryFragmentImpl? get enclosingFragment {
    return enclosingElement3;
  }

  @override
  LibraryFragmentImpl get enclosingUnit {
    return this;
  }

  List<EnumFragmentImpl> get enums {
    return _enums;
  }

  /// Set the enums contained in this compilation unit to the given [enums].
  set enums(List<EnumFragmentImpl> enums) {
    for (var element in enums) {
      element.enclosingElement3 = this;
    }
    _enums = enums;
  }

  @override
  List<EnumFragmentImpl> get enums2 => enums;

  List<ExtensionFragmentImpl> get extensions {
    return _extensions;
  }

  /// Set the extensions contained in this compilation unit to the given
  /// [extensions].
  set extensions(List<ExtensionFragmentImpl> extensions) {
    for (var extension in extensions) {
      extension.enclosingElement3 = this;
    }
    _extensions = extensions;
  }

  @override
  List<ExtensionFragmentImpl> get extensions2 => extensions;

  List<ExtensionTypeFragmentImpl> get extensionTypes {
    return _extensionTypes;
  }

  set extensionTypes(List<ExtensionTypeFragmentImpl> elements) {
    for (var element in elements) {
      element.enclosingElement3 = this;
    }
    _extensionTypes = elements;
  }

  @override
  List<ExtensionTypeFragmentImpl> get extensionTypes2 => extensionTypes;

  List<TopLevelFunctionFragmentImpl> get functions {
    return _functions;
  }

  /// Set the top-level functions contained in this compilation unit to the
  ///  given[functions].
  set functions(List<TopLevelFunctionFragmentImpl> functions) {
    for (var function in functions) {
      function.enclosingElement3 = this;
    }
    _functions = functions;
  }

  @override
  List<TopLevelFunctionFragment> get functions2 =>
      functions.cast<TopLevelFunctionFragment>();

  @override
  List<GetterFragmentImpl> get getters => _getters;

  set getters(List<GetterFragmentImpl> getters) {
    for (var getter in getters) {
      getter.enclosingElement3 = this;
    }
    _getters = getters;
  }

  @override
  int get hashCode => source.hashCode;

  @override
  String get identifier => '${source.uri}';

  @override
  List<LibraryElement> get importedLibraries2 {
    return libraryImports2
        .map((import) => import.importedLibrary2)
        .nonNulls
        .toSet()
        .toList();
  }

  @override
  ElementKind get kind => ElementKind.COMPILATION_UNIT;

  /// The libraries exported by this unit.
  List<LibraryExportImpl> get libraryExports {
    _ensureReadResolution();
    return _libraryExports;
  }

  set libraryExports(List<LibraryExportImpl> exports) {
    for (var exportElement in exports) {
      exportElement.libraryFragment = this;
    }
    _libraryExports = exports;
  }

  @override
  List<LibraryExport> get libraryExports2 =>
      libraryExports.cast<LibraryExport>();

  List<LibraryExportImpl> get libraryExports_unresolved {
    return _libraryExports;
  }

  @override
  LibraryFragment get libraryFragment => this;

  /// The libraries imported by this unit.
  List<LibraryImportImpl> get libraryImports {
    _ensureReadResolution();
    return _libraryImports;
  }

  set libraryImports(List<LibraryImportImpl> imports) {
    for (var importElement in imports) {
      importElement.libraryFragment = this;
    }
    _libraryImports = imports;
  }

  @override
  List<LibraryImportImpl> get libraryImports2 =>
      libraryImports.cast<LibraryImportImpl>();

  List<LibraryImportImpl> get libraryImports_unresolved {
    return _libraryImports;
  }

  @override
  Source get librarySource => library.source;

  List<MixinFragmentImpl> get mixins {
    return _mixins;
  }

  /// Set the mixins contained in this compilation unit to the given [mixins].
  set mixins(List<MixinFragmentImpl> mixins) {
    for (var mixin_ in mixins) {
      mixin_.enclosingElement3 = this;
    }
    _mixins = mixins;
  }

  @override
  List<MixinFragmentImpl> get mixins2 => mixins;

  @override
  String? get name2 => null;

  @override
  int? get nameOffset2 => null;

  @override
  LibraryFragment? get nextFragment {
    var units = library.units;
    var index = units.indexOf(this);
    return units.elementAtOrNull(index + 1);
  }

  @override
  int get offset {
    if (!identical(this, library.definingCompilationUnit)) {
      // Not the first fragment, so there is no name; return an offset of 0
      return 0;
    }
    if (library.nameOffset < 0) {
      // There is no name, so return an offset of 0
      return 0;
    }
    return library.nameOffset;
  }

  @override
  List<PartInclude> get partIncludes => parts.cast<PartInclude>();

  /// The parts included by this unit.
  List<PartIncludeImpl> get parts => _parts;

  set parts(List<PartIncludeImpl> parts) {
    for (var part in parts) {
      part.libraryFragment = this;
      if (part.uri case DirectiveUriWithUnitImpl uri) {
        uri.libraryFragment.enclosingElement3 = this;
      }
    }
    _parts = parts;
  }

  @override
  List<PrefixElementImpl> get prefixes {
    return _libraryImportPrefixes2 ??= _buildLibraryImportPrefixes2();
  }

  @override
  LibraryFragment? get previousFragment {
    var units = library.units;
    var index = units.indexOf(this);
    if (index >= 1) {
      return units[index - 1];
    }
    return null;
  }

  @override
  LibraryFragmentScope get scope {
    return _scope ??= LibraryFragmentScope(this);
  }

  @override
  AnalysisSession get session => library.session;

  @override
  List<SetterFragmentImpl> get setters => _setters;

  set setters(List<SetterFragmentImpl> setters) {
    for (var setter in setters) {
      setter.enclosingElement3 = this;
    }
    _setters = setters;
  }

  List<TopLevelVariableFragmentImpl> get topLevelVariables {
    return _variables;
  }

  /// Set the top-level variables contained in this compilation unit to the
  ///  given[variables].
  set topLevelVariables(List<TopLevelVariableFragmentImpl> variables) {
    for (var variable in variables) {
      variable.enclosingElement3 = this;
    }
    _variables = variables;
  }

  @override
  List<TopLevelVariableFragmentImpl> get topLevelVariables2 =>
      topLevelVariables;

  List<TypeAliasFragmentImpl> get typeAliases {
    return _typeAliases;
  }

  /// Set the type aliases contained in this compilation unit to [typeAliases].
  set typeAliases(List<TypeAliasFragmentImpl> typeAliases) {
    for (var typeAlias in typeAliases) {
      typeAlias.enclosingElement3 = this;
    }
    _typeAliases = typeAliases;
  }

  @override
  List<TypeAliasFragment> get typeAliases2 =>
      typeAliases.cast<TypeAliasFragment>();

  void addClass(ClassFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _classes = [..._classes, fragment];
    fragment.enclosingElement3 = this;
  }

  void addEnum(EnumFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _enums = [..._enums, fragment];
    fragment.enclosingElement3 = this;
  }

  void addExtension(ExtensionFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _extensions = [..._extensions, fragment];
    fragment.enclosingElement3 = this;
  }

  void addExtensionType(ExtensionTypeFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _extensionTypes = [..._extensionTypes, fragment];
    fragment.enclosingElement3 = this;
  }

  void addFunction(TopLevelFunctionFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _functions = [..._functions, fragment];
    fragment.enclosingElement3 = this;
  }

  void addGetter(GetterFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _getters = [..._getters, fragment];
    fragment.enclosingElement3 = this;
  }

  void addMixin(MixinFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _mixins = [..._mixins, fragment];
    fragment.enclosingElement3 = this;
  }

  void addSetter(SetterFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _setters = [..._setters, fragment];
    fragment.enclosingElement3 = this;
  }

  void addTopLevelVariable(TopLevelVariableFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _variables = [..._variables, fragment];
    fragment.enclosingElement3 = this;
  }

  void addTypeAlias(TypeAliasFragmentImpl fragment) {
    // TODO(scheglov): optimize
    _typeAliases = [..._typeAliases, fragment];
    fragment.enclosingElement3 = this;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeCompilationUnitElement(this);
  }

  /// Indicates whether it is unnecessary to report an undefined identifier
  /// error for an identifier reference with the given [name] and optional
  /// [prefix].
  ///
  /// This method is intended to reduce spurious errors in circumstances where
  /// an undefined identifier occurs as the result of a missing (most likely
  /// code generated) file.  It will only return `true` in a circumstance where
  /// the current library is guaranteed to have at least one other error (due to
  /// a missing part or import), so there is no risk that ignoring the undefined
  /// identifier would cause an invalid program to be treated as valid.
  bool shouldIgnoreUndefined({required String? prefix, required String name}) {
    for (var libraryFragment in withEnclosing) {
      for (var importElement in libraryFragment.libraryImports) {
        if (importElement.prefix2?.element.name3 == prefix &&
            importElement.importedLibrary2?.isSynthetic != false) {
          var showCombinators =
              importElement.combinators
                  .whereType<ShowElementCombinator>()
                  .toList();
          if (prefix != null && showCombinators.isEmpty) {
            return true;
          }
          for (var combinator in showCombinators) {
            if (combinator.shownNames.contains(name)) {
              return true;
            }
          }
        }
      }
    }

    if (prefix == null && name.startsWith(r'_$')) {
      for (var partElement in parts) {
        var uri = partElement.uri;
        if (uri is DirectiveUriWithSourceImpl &&
            uri is! DirectiveUriWithUnitImpl &&
            file_paths.isGenerated(uri.relativeUriString)) {
          return true;
        }
      }
    }

    return false;
  }

  /// Convenience wrapper around [shouldIgnoreUndefined] that calls it for a
  /// given (possibly prefixed) identifier [node].
  bool shouldIgnoreUndefinedIdentifier(Identifier node) {
    if (node is PrefixedIdentifier) {
      return shouldIgnoreUndefined(
        prefix: node.prefix.name,
        name: node.identifier.name,
      );
    }

    return shouldIgnoreUndefined(
      prefix: null,
      name: (node as SimpleIdentifier).name,
    );
  }

  /// Convenience wrapper around [shouldIgnoreUndefined] that calls it for a
  /// given (possibly prefixed) named type [node].
  bool shouldIgnoreUndefinedNamedType(NamedType node) {
    return shouldIgnoreUndefined(
      prefix: node.importPrefix?.name.lexeme,
      name: node.name.lexeme,
    );
  }

  List<PrefixElementImpl> _buildLibraryImportPrefixes2() {
    var prefixes = <PrefixElementImpl>{};
    for (var import in libraryImports2) {
      var prefix = import.prefix2?.element;
      if (prefix != null) {
        prefixes.add(prefix);
      }
    }
    return prefixes.toFixedList();
  }
}

class LibraryImportImpl extends ElementDirectiveImpl implements LibraryImport {
  @override
  final bool isSynthetic;

  @override
  final List<NamespaceCombinator> combinators;

  @override
  int importKeywordOffset;

  @override
  final PrefixFragmentImpl? prefix2;

  Namespace? _namespace;

  LibraryImportImpl({
    required super.uri,
    required this.isSynthetic,
    required this.combinators,
    required this.importKeywordOffset,
    required this.prefix2,
  });

  @override
  LibraryElementImpl? get importedLibrary2 {
    if (uri case DirectiveUriWithLibraryImpl uri) {
      return uri.library2;
    }
    return null;
  }

  @override
  Namespace get namespace {
    var uri = this.uri;
    if (uri is DirectiveUriWithLibraryImpl) {
      return _namespace ??= NamespaceBuilder()
          .createImportNamespaceForDirective(
            importedLibrary: uri.library2,
            combinators: combinators,
            prefix: prefix2,
          );
    }
    return Namespace.EMPTY;
  }
}

/// The provider for the lazily created `loadLibrary` function.
final class LoadLibraryFunctionProvider {
  final Reference elementReference;
  TopLevelFunctionElementImpl? _element;

  LoadLibraryFunctionProvider({required this.elementReference});

  TopLevelFunctionElementImpl getElement(LibraryElementImpl library) {
    return _element ??= _create(library);
  }

  TopLevelFunctionElementImpl _create(LibraryElementImpl library) {
    var name = TopLevelFunctionElement.LOAD_LIBRARY_NAME;

    var fragment = TopLevelFunctionFragmentImpl(name2: name, nameOffset: -1);
    fragment.isSynthetic = true;
    fragment.isStatic = true;
    fragment.returnType = library.typeProvider.futureDynamicType;
    fragment.enclosingElement3 = library.definingCompilationUnit;

    return TopLevelFunctionElementImpl(elementReference, fragment)
      ..returnType = library.typeProvider.futureDynamicType;
  }
}

class LocalFunctionElementImpl extends ExecutableElementImpl
    with WrappedElementMixin
    implements LocalFunctionElement {
  @override
  final LocalFunctionFragmentImpl _wrappedElement;

  LocalFunctionElementImpl(this._wrappedElement);

  @override
  String? get documentationComment => _wrappedElement.documentationComment;

  @override
  // Local functions belong to Fragments, not Elements.
  Element? get enclosingElement => null;

  @Deprecated('Use enclosingElement instead')
  @override
  Element? get enclosingElement2 => enclosingElement;

  @override
  LocalFunctionFragmentImpl get firstFragment => _wrappedElement;

  @override
  List<FormalParameterElementMixin> get formalParameters =>
      _wrappedElement.formalParameters
          .map((fragment) => fragment.element)
          .toList();

  @override
  List<LocalFunctionFragmentImpl> get fragments {
    return [
      for (
        LocalFunctionFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  bool get hasImplicitReturnType => _wrappedElement.hasImplicitReturnType;

  @override
  bool get isAbstract => _wrappedElement.isAbstract;

  @override
  bool get isExtensionTypeMember => _wrappedElement.isExtensionTypeMember;

  @override
  bool get isExternal => false;

  @override
  bool get isSimplyBounded => _wrappedElement.isSimplyBounded;

  @override
  bool get isStatic => _wrappedElement.isStatic;

  @override
  MetadataImpl get metadata => _wrappedElement.metadata;

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  TypeImpl get returnType => _wrappedElement.returnType;

  @override
  FunctionTypeImpl get type => _wrappedElement.type;

  @override
  List<TypeParameterElement> get typeParameters2 =>
      _wrappedElement.typeParameters
          .map((fragment) => (fragment as TypeParameterFragment).element)
          .toList();

  FunctionFragmentImpl get wrappedElement {
    return _wrappedElement;
  }

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitLocalFunctionElement(this);
  }
}

/// A concrete implementation of a [LocalFunctionFragment].
class LocalFunctionFragmentImpl extends FunctionFragmentImpl
    implements LocalFunctionFragment {
  /// The element corresponding to this fragment.
  @override
  late final LocalFunctionElementImpl element = LocalFunctionElementImpl(this);

  @override
  LocalFunctionFragmentImpl? previousFragment;

  @override
  LocalFunctionFragmentImpl? nextFragment;

  LocalFunctionFragmentImpl({required super.name2, required super.nameOffset});

  LocalFunctionFragmentImpl.forOffset(super.nameOffset) : super.forOffset();

  @override
  bool get _includeNameOffsetInIdentifier {
    return super._includeNameOffsetInIdentifier ||
        enclosingElement3 is ExecutableFragment ||
        enclosingElement3 is VariableFragment;
  }
}

class LocalVariableElementImpl extends PromotableElementImpl
    with WrappedElementMixin, _NonTopLevelVariableOrParameter
    implements LocalVariableElement {
  @override
  final LocalVariableFragmentImpl _wrappedElement;

  LocalVariableElementImpl(this._wrappedElement);

  @override
  LocalVariableElement get baseElement => this;

  @override
  String? get documentationComment => null;

  @override
  LocalVariableFragmentImpl get firstFragment => _wrappedElement;

  @override
  List<LocalVariableFragmentImpl> get fragments {
    return [firstFragment];
  }

  @override
  bool get hasImplicitType => _wrappedElement.hasImplicitType;

  @override
  bool get hasInitializer => _wrappedElement.hasInitializer;

  @override
  bool get isConst => _wrappedElement.isConst;

  @override
  bool get isFinal => _wrappedElement.isFinal;

  @override
  bool get isLate => _wrappedElement.isLate;

  @override
  bool get isStatic => _wrappedElement.isStatic;

  @override
  LibraryElementImpl get library2 {
    return _wrappedElement.library;
  }

  @override
  MetadataImpl get metadata => _wrappedElement.metadata;

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  TypeImpl get type => _wrappedElement.type;

  set type(TypeImpl type) => _wrappedElement.type = type;

  LocalVariableFragmentImpl get wrappedElement {
    return _wrappedElement;
  }

  @override
  FragmentImpl? get _enclosingFunction => _wrappedElement.enclosingElement3;

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitLocalVariableElement(this);
  }

  @override
  DartObject? computeConstantValue() => _wrappedElement.computeConstantValue();
}

class LocalVariableFragmentImpl extends NonParameterVariableFragmentImpl
    implements LocalVariableFragment, VariableElementOrMember {
  late LocalVariableElementImpl _element2 = switch (this) {
    BindPatternVariableFragmentImpl() => BindPatternVariableElementImpl(this),
    JoinPatternVariableFragmentImpl() => JoinPatternVariableElementImpl(this),
    PatternVariableFragmentImpl() => PatternVariableElementImpl(this),
    _ => LocalVariableElementImpl(this),
  };

  @override
  final String? name2;

  @override
  MetadataImpl metadata = MetadataImpl(const []);

  @override
  late bool hasInitializer;

  /// Initialize a newly created method element to have the given [name] and
  /// [offset].
  LocalVariableFragmentImpl({required this.name2, required super.nameOffset});

  @override
  List<Fragment> get children3 => const [];

  @override
  LocalVariableElementImpl get element => _element2;

  @override
  Fragment get enclosingFragment => enclosingElement3 as Fragment;

  set enclosingFragment(Fragment value) {
    enclosingElement3 = value as FragmentImpl;
  }

  @override
  String get identifier {
    return '$name2$nameOffset';
  }

  @override
  bool get isLate {
    return hasModifier(Modifier.LATE);
  }

  @override
  ElementKind get kind => ElementKind.LOCAL_VARIABLE;

  @override
  LibraryElementImpl get library2 => library;

  @override
  LibraryFragmentImpl get libraryFragment => enclosingUnit;

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  // TODO(scheglov): make it a nullable field
  int? get nameOffset2 => nameOffset;

  @override
  LocalVariableFragmentImpl? get nextFragment => null;

  @override
  LocalVariableFragmentImpl? get previousFragment => null;
}

final class MetadataImpl implements Metadata {
  static const _isReady = 1 << 0;
  static const _hasDeprecated = 1 << 1;
  static const _hasOverride = 1 << 2;

  /// Cached flags denoting presence of specific annotations.
  int _metadataFlags2 = 0;

  @override
  final List<ElementAnnotationImpl> annotations;

  MetadataImpl(this.annotations);

  @override
  bool get hasAlwaysThrows {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isAlwaysThrows) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasAwaitNotRequired {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isAwaitNotRequired) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasDeprecated {
    return (_getMetadataFlags() & _hasDeprecated) != 0;
  }

  @override
  bool get hasDoNotStore {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isDoNotStore) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasDoNotSubmit {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isDoNotSubmit) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasExperimental {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isExperimental) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasFactory {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isFactory) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasImmutable {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isImmutable) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasInternal {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isInternal) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasIsTest {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isIsTest) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasIsTestGroup {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isIsTestGroup) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasJS {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isJS) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasLiteral {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isLiteral) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasMustBeConst {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isMustBeConst) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasMustBeOverridden {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isMustBeOverridden) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasMustCallSuper {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isMustCallSuper) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasNonVirtual {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isNonVirtual) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasOptionalTypeArgs {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isOptionalTypeArgs) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasOverride {
    return (_getMetadataFlags() & _hasOverride) != 0;
  }

  /// Return `true` if this element has an annotation of the form
  /// `@pragma("vm:entry-point")`.
  bool get hasPragmaVmEntryPoint {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isPragmaVmEntryPoint) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasProtected {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isProtected) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasRedeclare {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isRedeclare) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasReopen {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isReopen) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasRequired {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isRequired) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasSealed {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isSealed) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasUseResult {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isUseResult) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasVisibleForOverriding {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isVisibleForOverriding) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasVisibleForTemplate {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isVisibleForTemplate) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasVisibleForTesting {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isVisibleForTesting) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasVisibleOutsideTemplate {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isVisibleOutsideTemplate) {
        return true;
      }
    }
    return false;
  }

  @override
  bool get hasWidgetFactory {
    var annotations = this.annotations;
    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isWidgetFactory) {
        return true;
      }
    }
    return false;
  }

  void resetCache() {
    _metadataFlags2 = 0;
  }

  /// Return flags that denote presence of a few specific annotations.
  int _getMetadataFlags() {
    var result = _metadataFlags2;

    // Has at least `_metadataFlag_isReady`.
    if (result != 0) {
      return result;
    }

    for (var i = 0; i < annotations.length; i++) {
      var annotation = annotations[i];
      if (annotation.isDeprecated) {
        result |= _hasDeprecated;
      } else if (annotation.isOverride) {
        result |= _hasOverride;
      }
    }

    result |= _isReady;
    return _metadataFlags2 = result;
  }
}

/// Common base class for all analyzer-internal classes that implement
/// `MethodElement2`.
abstract class MethodElement2OrMember
    implements MethodElement, ExecutableElement2OrMember {
  @override
  MethodElementImpl get baseElement;
}

class MethodElementImpl extends ExecutableElementImpl
    with
        FragmentedExecutableElementMixin<MethodFragmentImpl>,
        FragmentedFunctionTypedElementMixin<MethodFragmentImpl>,
        FragmentedTypeParameterizedElementMixin<MethodFragmentImpl>,
        FragmentedAnnotatableElementMixin<MethodFragmentImpl>,
        FragmentedElementMixin<MethodFragmentImpl>,
        _HasSinceSdkVersionMixin
    implements MethodElement2OrMember {
  @override
  final Reference reference;

  @override
  final String? name3;

  @override
  final MethodFragmentImpl firstFragment;

  MethodElementImpl({
    required this.name3,
    required this.reference,
    required this.firstFragment,
  }) {
    reference.element = this;
    firstFragment.element = this;
  }

  @override
  MethodElementImpl get baseElement => this;

  @override
  String get displayName {
    return lookupName ?? '<unnamed>';
  }

  @override
  Element? get enclosingElement =>
      (firstFragment.enclosingElement3 as InstanceFragment).element;

  @Deprecated('Use enclosingElement instead')
  @override
  Element? get enclosingElement2 => enclosingElement;

  @override
  List<MethodFragmentImpl> get fragments {
    return [
      for (
        MethodFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  bool get isOperator => firstFragment.isOperator;

  @override
  ElementKind get kind => ElementKind.METHOD;

  @override
  MethodFragmentImpl get lastFragment {
    return super.lastFragment as MethodFragmentImpl;
  }

  @override
  String? get lookupName {
    if (name3 == '-' && formalParameters.isEmpty) {
      return 'unary-';
    }
    return name3;
  }

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitMethodElement(this);
  }
}

/// Common base class for all analyzer-internal classes that implement
/// `MethodElement`.
abstract class MethodElementOrMember implements ExecutableElementOrMember {
  @override
  TypeImpl get returnType;

  @override
  FunctionTypeImpl get type;

  @override
  List<TypeParameterFragmentImpl> get typeParameters;
}

class MethodFragmentImpl extends ExecutableFragmentImpl
    implements MethodElementOrMember, MethodFragment {
  @override
  late final MethodElementImpl element;

  @override
  final String? name2;

  @override
  int? nameOffset2;

  @override
  MethodFragmentImpl? previousFragment;

  @override
  MethodFragmentImpl? nextFragment;

  /// Is `true` if this method is `operator==`, and there is no explicit
  /// type specified for its formal parameter, in this method or in any
  /// overridden methods other than the one declared in `Object`.
  bool isOperatorEqualWithParameterTypeFromObject = false;

  /// The error reported during type inference for this variable, or `null` if
  /// this variable is not a subject of type inference, or there was no error.
  TopLevelInferenceError? typeInferenceError;

  /// Initialize a newly created method element to have the given [name] at the
  /// given [offset].
  MethodFragmentImpl({required this.name2, required super.nameOffset});

  @override
  MethodFragmentImpl get declaration => this;

  @override
  String get displayName {
    String displayName = super.displayName;
    if ("unary-" == displayName) {
      return "-";
    }
    return displayName;
  }

  @override
  InstanceFragmentImpl get enclosingElement3 {
    return super.enclosingElement3 as InstanceFragmentImpl;
  }

  @override
  InstanceFragment? get enclosingFragment =>
      enclosingElement3 as InstanceFragment;

  /// Set whether this class is abstract.
  set isAbstract(bool isAbstract) {
    setModifier(Modifier.ABSTRACT, isAbstract);
  }

  @override
  bool get isOperator {
    String name = displayName;
    if (name.isEmpty) {
      return false;
    }
    int first = name.codeUnitAt(0);
    return !((0x61 <= first && first <= 0x7A) ||
        (0x41 <= first && first <= 0x5A) ||
        first == 0x5F ||
        first == 0x24);
  }

  @override
  ElementKind get kind => ElementKind.METHOD;

  @override
  String? get lookupName {
    if (name2 == '-' && formalParameters.isEmpty) {
      return 'unary-';
    }
    return name2;
  }

  @override
  FragmentImpl get nonSynthetic {
    if (isSynthetic && enclosingElement3 is EnumFragmentImpl) {
      return enclosingElement3;
    }
    return this;
  }

  void addFragment(MethodFragmentImpl fragment) {
    fragment.element = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }
}

class MixinElementImpl extends InterfaceElementImpl implements MixinElement {
  @override
  final Reference reference;

  @override
  final MixinFragmentImpl firstFragment;

  MixinElementImpl(this.reference, this.firstFragment) {
    reference.element = this;
    firstFragment.augmentedInternal = this;
  }

  @override
  List<MixinFragmentImpl> get fragments {
    return [
      for (
        MixinFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  bool get isBase => firstFragment.isBase;

  @override
  List<InterfaceTypeImpl> get superclassConstraints {
    return [for (var fragment in fragments) ...fragment.superclassConstraints];
  }

  /// Names of methods, getters, setters, and operators that this mixin
  /// declaration super-invokes.  For setters this includes the trailing "=".
  /// The list will be empty if this class is not a mixin declaration.
  List<String> get superInvokedNames => firstFragment.superInvokedNames;

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitMixinElement(this);
  }

  @override
  bool isImplementableIn2(LibraryElement library) {
    if (library == library2) {
      return true;
    }
    return !isBase;
  }
}

/// A [ClassFragmentImpl] representing a mixin declaration.
class MixinFragmentImpl extends ClassOrMixinFragmentImpl
    implements MixinFragment {
  List<InterfaceTypeImpl> _superclassConstraints = const [];

  /// Names of methods, getters, setters, and operators that this mixin
  /// declaration super-invokes.  For setters this includes the trailing "=".
  /// The list will be empty if this class is not a mixin declaration.
  late List<String> superInvokedNames;

  late MixinElementImpl augmentedInternal;

  /// Initialize a newly created class element to have the given [name] at the
  /// given [offset] in the file that contains the declaration of this element.
  MixinFragmentImpl({required super.name2, required super.nameOffset});

  @override
  MixinElementImpl get element {
    _ensureReadResolution();
    return augmentedInternal;
  }

  @override
  bool get isBase {
    return hasModifier(Modifier.BASE);
  }

  @override
  ElementKind get kind => ElementKind.MIXIN;

  @override
  List<InterfaceTypeImpl> get mixins => const [];

  @override
  set mixins(List<InterfaceType> mixins) {
    throw StateError('Attempt to set mixins for a mixin declaration.');
  }

  @override
  MixinFragmentImpl? get nextFragment =>
      super.nextFragment as MixinFragmentImpl?;

  @override
  MixinFragmentImpl? get previousFragment =>
      super.previousFragment as MixinFragmentImpl?;

  @override
  List<InterfaceTypeImpl> get superclassConstraints {
    _ensureReadResolution();
    return _superclassConstraints;
  }

  set superclassConstraints(List<InterfaceType> superclassConstraints) {
    // TODO(paulberry): eliminate this cast by changing the type of the
    // `superclassConstraints` parameter.
    _superclassConstraints = superclassConstraints.cast();
  }

  @override
  InterfaceTypeImpl? get supertype => null;

  @override
  set supertype(InterfaceType? supertype) {
    throw StateError('Attempt to set a supertype for a mixin declaration.');
  }

  void addFragment(MixinFragmentImpl fragment) {
    fragment.augmentedInternal = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeMixinElement(this);
  }
}

/// The constants for all of the modifiers defined by the Dart language and for
/// a few additional flags that are useful.
///
/// Clients may not extend, implement or mix-in this class.
enum Modifier {
  /// Indicates that the modifier 'abstract' was applied to the element.
  ABSTRACT,

  /// Indicates that an executable element has a body marked as being
  /// asynchronous.
  ASYNCHRONOUS,

  /// Indicates that the modifier 'augment' was applied to the element.
  AUGMENTATION,

  /// Indicates that the element is the start of the augmentation chain,
  /// in the simplest case - the declaration. But could be an augmentation
  /// that has no augmented declaration (which is a compile-time error).
  AUGMENTATION_CHAIN_START,

  /// Indicates that the modifier 'base' was applied to the element.
  BASE,

  /// Indicates that the modifier 'const' was applied to the element.
  CONST,

  /// Indicates that the modifier 'covariant' was applied to the element.
  COVARIANT,

  /// Indicates that the class is `Object` from `dart:core`.
  DART_CORE_OBJECT,

  /// Indicates that the import element represents a deferred library.
  DEFERRED,

  /// Indicates that a class element was defined by an enum declaration.
  ENUM,

  /// Indicates that the element is an enum constant field.
  ENUM_CONSTANT,

  /// Indicates that the element is an extension type member.
  EXTENSION_TYPE_MEMBER,

  /// Indicates that a class element was defined by an enum declaration.
  EXTERNAL,

  /// Indicates that the modifier 'factory' was applied to the element.
  FACTORY,

  /// Indicates that the modifier 'final' was applied to the element.
  FINAL,

  /// Indicates that an executable element has a body marked as being a
  /// generator.
  GENERATOR,

  /// Indicates that the pseudo-modifier 'get' was applied to the element.
  GETTER,

  /// Indicates that this class has an explicit `extends` clause.
  HAS_EXTENDS_CLAUSE,

  /// A flag used for libraries indicating that the variable has an explicit
  /// initializer.
  HAS_INITIALIZER,

  /// A flag used for libraries indicating that the defining compilation unit
  /// has a `part of` directive, meaning that this unit should be a part,
  /// but is used as a library.
  HAS_PART_OF_DIRECTIVE,

  /// Indicates that the value of [FragmentImpl.sinceSdkVersion] was computed.
  HAS_SINCE_SDK_VERSION_COMPUTED,

  /// [HAS_SINCE_SDK_VERSION_COMPUTED] and the value was not `null`.
  HAS_SINCE_SDK_VERSION_VALUE,

  /// Indicates that the associated element did not have an explicit type
  /// associated with it. If the element is an [ExecutableElement], then the
  /// type being referred to is the return type.
  IMPLICIT_TYPE,

  /// Indicates that the modifier 'interface' was applied to the element.
  INTERFACE,

  /// Indicates that the method invokes the super method with the same name.
  INVOKES_SUPER_SELF,

  /// Indicates that modifier 'lazy' was applied to the element.
  LATE,

  /// Indicates that a class is a mixin application.
  MIXIN_APPLICATION,

  /// Indicates that a class is a mixin class.
  MIXIN_CLASS,

  /// Whether the type of this fragment references a type parameter of the
  /// enclosing element. This includes not only explicitly specified type
  /// annotations, but also inferred types.
  NO_ENCLOSING_TYPE_PARAMETER_REFERENCE,
  PROMOTABLE,

  /// Indicates whether the type of a [PropertyInducingFragmentImpl] should be
  /// used to infer the initializer. We set it to `false` if the type was
  /// inferred from the initializer itself.
  SHOULD_USE_TYPE_FOR_INITIALIZER_INFERENCE,

  /// Indicates that the modifier 'sealed' was applied to the element.
  SEALED,

  /// Indicates that the pseudo-modifier 'set' was applied to the element.
  SETTER,

  /// See [TypeParameterizedElement.isSimplyBounded].
  SIMPLY_BOUNDED,

  /// Indicates that the modifier 'static' was applied to the element.
  STATIC,

  /// Indicates that the element does not appear in the source code but was
  /// implicitly created. For example, if a class does not define any
  /// constructors, an implicit zero-argument constructor will be created and it
  /// will be marked as being synthetic.
  SYNTHETIC,
}

class MultiplyDefinedElementImpl extends ElementImpl
    implements MultiplyDefinedElement {
  final LibraryFragmentImpl libraryFragment;

  @override
  final String name3;

  @override
  final List<Element> conflictingElements2;

  @override
  late final MultiplyDefinedFragmentImpl firstFragment =
      MultiplyDefinedFragmentImpl(this);

  MultiplyDefinedElementImpl(
    this.libraryFragment,
    this.name3,
    this.conflictingElements2,
  );

  @override
  MultiplyDefinedElementImpl get baseElement => this;

  @override
  List<Element> get children2 => const [];

  @override
  String get displayName => name3;

  @override
  Null get enclosingElement => null;

  @Deprecated('Use enclosingElement instead')
  @override
  Null get enclosingElement2 => enclosingElement;

  @override
  List<MultiplyDefinedFragmentImpl> get fragments {
    return [firstFragment];
  }

  @override
  bool get isPrivate => false;

  @override
  bool get isPublic => true;

  @override
  bool get isSynthetic => true;

  bool get isVisibleForTemplate => false;

  bool get isVisibleOutsideTemplate => false;

  @override
  ElementKind get kind => ElementKind.ERROR;

  @override
  LibraryElement get library2 => libraryFragment.element;

  @override
  Element get nonSynthetic => this;

  @override
  AnalysisSession get session => libraryFragment.session;

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitMultiplyDefinedElement(this);
  }

  @override
  String displayString2({
    bool multiline = false,
    bool preferTypeAlias = false,
  }) {
    var elementsStr = conflictingElements2
        .map((e) {
          return e.displayString2();
        })
        .join(', ');
    return '[$elementsStr]';
  }

  @override
  bool isAccessibleIn2(LibraryElement library) {
    for (var element in conflictingElements2) {
      if (element.isAccessibleIn2(library)) {
        return true;
      }
    }
    return false;
  }

  @override
  Element? thisOrAncestorMatching2(bool Function(Element p1) predicate) {
    return null;
  }

  @override
  E? thisOrAncestorOfType2<E extends Element>() {
    return null;
  }

  @override
  String toString() {
    StringBuffer buffer = StringBuffer();
    bool needsSeparator = false;
    void writeList(List<Element> elements) {
      for (var element in elements) {
        if (needsSeparator) {
          buffer.write(", ");
        } else {
          needsSeparator = true;
        }
        buffer.write(element.displayString2());
      }
    }

    buffer.write("[");
    writeList(conflictingElements2);
    buffer.write("]");
    return buffer.toString();
  }

  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {
    for (var child in children2) {
      child.accept2(visitor);
    }
  }
}

class MultiplyDefinedFragmentImpl implements MultiplyDefinedFragment {
  @override
  final MultiplyDefinedElementImpl element;

  MultiplyDefinedFragmentImpl(this.element);

  @override
  List<Fragment> get children3 => [];

  @override
  LibraryFragment get enclosingFragment => element.libraryFragment;

  @override
  LibraryFragment get libraryFragment => enclosingFragment;

  @override
  String? get name2 => element.name3;

  @override
  Null get nameOffset2 => null;

  @override
  Null get nextFragment => null;

  @override
  int get offset => 0;

  @override
  Null get previousFragment => null;
}

/// The synthetic element representing the declaration of the type `Never`.
class NeverElementImpl extends TypeDefiningElementImpl {
  /// The unique instance of this class.
  static final instance = NeverElementImpl._();

  NeverElementImpl._();

  @override
  Null get documentationComment => null;

  @override
  Element? get enclosingElement => null;

  @Deprecated('Use enclosingElement instead')
  @override
  Element? get enclosingElement2 => enclosingElement;

  @override
  NeverFragmentImpl get firstFragment => NeverFragmentImpl.instance;

  @override
  List<NeverFragmentImpl> get fragments {
    return [firstFragment];
  }

  @override
  bool get isSynthetic => true;

  @override
  ElementKind get kind => ElementKind.NEVER;

  @override
  Null get library2 => null;

  @override
  MetadataImpl get metadata {
    return MetadataImpl(const []);
  }

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  String get name3 => 'Never';

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return null;
  }

  DartType instantiate({required NullabilitySuffix nullabilitySuffix}) {
    switch (nullabilitySuffix) {
      case NullabilitySuffix.question:
        return NeverTypeImpl.instanceNullable;
      case NullabilitySuffix.star:
        // TODO(scheglov): remove together with `star`
        return NeverTypeImpl.instanceNullable;
      case NullabilitySuffix.none:
        return NeverTypeImpl.instance;
    }
  }
}

/// The synthetic element representing the declaration of the type `Never`.
class NeverFragmentImpl extends FragmentImpl implements TypeDefiningFragment {
  /// The unique instance of this class.
  static final instance = NeverFragmentImpl._();

  @override
  final MetadataImpl metadata = MetadataImpl(const []);

  /// Initialize a newly created instance of this class. Instances of this class
  /// should <b>not</b> be created except as part of creating the type
  /// associated with this element. The single instance of this class should be
  /// accessed through the method [instance].
  NeverFragmentImpl._() : super(nameOffset: -1) {
    setModifier(Modifier.SYNTHETIC, true);
  }

  @override
  List<Fragment> get children3 => const [];

  @override
  NeverElementImpl get element => NeverElementImpl.instance;

  @override
  Null get enclosingFragment => null;

  @override
  ElementKind get kind => ElementKind.NEVER;

  @override
  Null get library => null;

  @override
  Null get libraryFragment => null;

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  String get name2 => 'Never';

  @override
  Null get nameOffset2 => null;

  @override
  Null get nextFragment => null;

  @override
  int get offset => 0;

  @override
  Null get previousFragment => null;

  DartType instantiate({required NullabilitySuffix nullabilitySuffix}) {
    switch (nullabilitySuffix) {
      case NullabilitySuffix.question:
        return NeverTypeImpl.instanceNullable;
      case NullabilitySuffix.star:
        // TODO(scheglov): remove together with `star`
        return NeverTypeImpl.instanceNullable;
      case NullabilitySuffix.none:
        return NeverTypeImpl.instance;
    }
  }
}

/// A [VariableFragmentImpl], which is not a parameter.
abstract class NonParameterVariableFragmentImpl extends VariableFragmentImpl
    with _HasLibraryMixin {
  /// Initialize a newly created variable element to have the given [name] and
  /// [offset].
  NonParameterVariableFragmentImpl({required super.nameOffset});

  @override
  FragmentImpl get enclosingElement3 {
    // TODO(paulberry): `!` is not appropriate here because variable elements
    // aren't guaranteed to have enclosing elements. See
    // https://github.com/dart-lang/sdk/issues/59750.
    return super.enclosingElement3 as FragmentImpl;
  }

  bool get hasInitializer {
    return hasModifier(Modifier.HAS_INITIALIZER);
  }

  /// Set whether this variable has an initializer.
  set hasInitializer(bool hasInitializer) {
    setModifier(Modifier.HAS_INITIALIZER, hasInitializer);
  }
}

/// A mixin that provides a common implementation for methods defined in
/// `ParameterElement`.
mixin ParameterElementMixin implements VariableElementOrMember {
  @override
  FormalParameterFragmentImpl get declaration;

  /// The code of the default value, or `null` if no default value.
  String? get defaultValueCode;

  @override
  FormalParameterElementImpl get element;

  /// Whether the parameter is covariant, meaning it is allowed to have a
  /// narrower type in an override.
  bool get isCovariant;

  /// Whether the parameter is an initializing formal parameter.
  bool get isInitializingFormal;

  /// Whether the parameter is a named parameter.
  ///
  /// Named parameters that are annotated with the `@required` annotation are
  /// considered optional. Named parameters that are annotated with the
  /// `required` syntax are considered required.
  bool get isNamed => parameterKind.isNamed;

  /// Whether the parameter is an optional parameter.
  ///
  /// Optional parameters can either be positional or named. Named parameters
  /// that are annotated with the `@required` annotation are considered
  /// optional. Named parameters that are annotated with the `required` syntax
  /// are considered required.
  bool get isOptional => parameterKind.isOptional;

  /// Whether the parameter is both an optional and named parameter.
  ///
  /// Named parameters that are annotated with the `@required` annotation are
  /// considered optional. Named parameters that are annotated with the
  /// `required` syntax are considered required.
  bool get isOptionalNamed => parameterKind.isOptionalNamed;

  /// Whether the parameter is both an optional and positional parameter.
  bool get isOptionalPositional => parameterKind.isOptionalPositional;

  /// Whether the parameter is a positional parameter.
  ///
  /// Positional parameters can either be required or optional.
  bool get isPositional => parameterKind.isPositional;

  /// Whether the parameter is either a required positional parameter, or a
  /// named parameter with the `required` keyword.
  ///
  /// Note: the presence or absence of the `@required` annotation does not
  /// change the meaning of this getter. The parameter `{@required int x}`
  /// will return `false` and the parameter `{@required required int x}`
  /// will return `true`.
  bool get isRequired => parameterKind.isRequired;

  /// Whether the parameter is both a required and named parameter.
  ///
  /// Named parameters that are annotated with the `@required` annotation are
  /// considered optional. Named parameters that are annotated with the
  /// `required` syntax are considered required.
  bool get isRequiredNamed => parameterKind.isRequiredNamed;

  /// Whether the parameter is both a required and positional parameter.
  bool get isRequiredPositional => parameterKind.isRequiredPositional;

  @override
  MetadataImpl get metadata;

  ParameterKind get parameterKind;

  /// The parameters defined by this parameter.
  ///
  /// A parameter will only define other parameters if it is a function typed
  /// parameter.
  List<ParameterElementMixin> get parameters;

  @override
  TypeImpl get type;

  /// The type parameters defined by this parameter.
  ///
  /// A parameter will only define type parameters if it is a function typed
  /// parameter.
  List<TypeParameterFragmentImpl> get typeParameters;

  /// Appends the type, name and possibly the default value of this parameter
  /// to the given [buffer].
  void appendToWithoutDelimiters(
    StringBuffer buffer, {
    @Deprecated('Only non-nullable by default mode is supported')
    bool withNullability = true,
  }) {
    buffer.write(
      type.getDisplayString(
        // ignore:deprecated_member_use_from_same_package
        withNullability: withNullability,
      ),
    );
    buffer.write(' ');
    buffer.write(displayName);
    if (defaultValueCode != null) {
      buffer.write(' = ');
      buffer.write(defaultValueCode);
    }
  }
}

class PartIncludeImpl extends ElementDirectiveImpl implements PartInclude {
  PartIncludeImpl({required super.uri});

  @override
  LibraryFragmentImpl? get includedFragment {
    if (uri case DirectiveUriWithUnitImpl uri) {
      return uri.libraryFragment;
    }
    return null;
  }
}

class PatternVariableElementImpl extends LocalVariableElementImpl
    implements PatternVariableElement {
  PatternVariableElementImpl(super._wrappedElement);

  @override
  PatternVariableFragmentImpl get firstFragment =>
      super.firstFragment as PatternVariableFragmentImpl;

  @override
  List<PatternVariableFragmentImpl> get fragments {
    return [
      for (
        PatternVariableFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  /// This flag is set to `true` while we are visiting the [WhenClause] of
  /// the [GuardedPattern] that declares this variable.
  bool get isVisitingWhenClause => _wrappedElement.isVisitingWhenClause;

  /// This flag is set to `true` while we are visiting the [WhenClause] of
  /// the [GuardedPattern] that declares this variable.
  set isVisitingWhenClause(bool value) =>
      _wrappedElement.isVisitingWhenClause = value;

  @override
  JoinPatternVariableElementImpl? get join2 {
    return _wrappedElement.join?.asElement2;
  }

  /// Return the root [join2], or self.
  PatternVariableElementImpl get rootVariable {
    return join2?.rootVariable ?? this;
  }

  @override
  PatternVariableFragmentImpl get _wrappedElement =>
      super._wrappedElement as PatternVariableFragmentImpl;

  static PatternVariableElement fromElement(
    PatternVariableFragmentImpl element,
  ) {
    if (element is JoinPatternVariableFragmentImpl) {
      return JoinPatternVariableElementImpl(element);
    } else if (element is BindPatternVariableFragmentImpl) {
      return BindPatternVariableElementImpl(element);
    }
    return PatternVariableElementImpl(element);
  }
}

class PatternVariableFragmentImpl extends LocalVariableFragmentImpl
    implements PatternVariableFragment {
  /// The variable in which this variable joins with other pattern variables
  /// with the same name, in a logical-or pattern, or shared case scope.
  JoinPatternVariableFragmentImpl? join;

  /// This flag is set to `true` while we are visiting the [WhenClause] of
  /// the [GuardedPattern] that declares this variable.
  bool isVisitingWhenClause = false;

  PatternVariableFragmentImpl({
    required super.name2,
    required super.nameOffset,
  });

  @override
  PatternVariableElementImpl get element =>
      super.element as PatternVariableElementImpl;

  @override
  JoinPatternVariableFragment? get join2 => join;

  @override
  PatternVariableFragmentImpl? get nextFragment =>
      super.nextFragment as PatternVariableFragmentImpl?;

  @override
  PatternVariableFragmentImpl? get previousFragment =>
      super.previousFragment as PatternVariableFragmentImpl?;

  /// Return the root [join], or self.
  PatternVariableFragmentImpl get rootVariable {
    return join?.rootVariable ?? this;
  }
}

class PrefixElementImpl extends ElementImpl implements PrefixElement {
  @override
  final Reference reference;

  @override
  final PrefixFragmentImpl firstFragment;

  PrefixFragmentImpl lastFragment;

  /// The scope of this prefix, `null` if not set yet.
  PrefixScope? _scope;

  PrefixElementImpl({required this.reference, required this.firstFragment})
    : lastFragment = firstFragment {
    reference.element = this;
  }

  @override
  Null get enclosingElement => null;

  @Deprecated('Use enclosingElement instead')
  @override
  Null get enclosingElement2 => enclosingElement;

  @override
  List<PrefixFragmentImpl> get fragments {
    return [
      for (
        PrefixFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  List<LibraryImportImpl> get imports {
    return firstFragment.enclosingFragment.libraryImports
        .where((import) => import.prefix2?.element == this)
        .toList();
  }

  @override
  bool get isSynthetic => false;

  @override
  ElementKind get kind => ElementKind.PREFIX;

  @override
  LibraryElementImpl get library2 {
    return firstFragment.libraryFragment.element;
  }

  @override
  String? get name3 => firstFragment.name2;

  @override
  PrefixScope get scope {
    firstFragment.enclosingFragment.scope;
    // SAFETY: The previous statement initializes this field.
    return _scope!;
  }

  set scope(PrefixScope value) {
    _scope = value;
  }

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitPrefixElement(this);
  }

  void addFragment(PrefixFragmentImpl fragment) {
    lastFragment.nextFragment = fragment;
    fragment.previousFragment = lastFragment;
    lastFragment = fragment;
  }

  @override
  String displayString2({
    bool multiline = false,
    bool preferTypeAlias = false,
  }) {
    var builder = ElementDisplayStringBuilder(
      multiline: multiline,
      preferTypeAlias: preferTypeAlias,
    );
    builder.writePrefixElement2(this);
    return builder.toString();
  }

  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {}
}

class PrefixFragmentImpl implements PrefixFragment {
  @override
  final LibraryFragmentImpl enclosingFragment;

  @override
  final String? name2;

  @override
  int? nameOffset2;

  @override
  int offset = 0;

  @override
  final bool isDeferred;

  @override
  late final PrefixElementImpl element;

  @override
  PrefixFragmentImpl? previousFragment;

  @override
  PrefixFragmentImpl? nextFragment;

  PrefixFragmentImpl({
    required this.enclosingFragment,
    required this.name2,
    required this.nameOffset2,
    required this.isDeferred,
  });

  @override
  List<Fragment> get children3 => const [];

  @override
  LibraryFragmentImpl get libraryFragment => enclosingFragment;
}

abstract class PromotableElementImpl extends VariableElementImpl
    implements PromotableElement {}

/// Common base class for all analyzer-internal classes that implement
/// `PropertyAccessorElement2`.
abstract class PropertyAccessorElement2OrMember
    implements PropertyAccessorElement, ExecutableElement2OrMember {
  @override
  PropertyAccessorElementImpl get baseElement;

  @override
  PropertyInducingElement2OrMember? get variable3;
}

abstract class PropertyAccessorElementImpl extends ExecutableElementImpl
    implements PropertyAccessorElement2OrMember {
  PropertyInducingElementImpl? _variable3;

  @override
  PropertyAccessorElementImpl get baseElement => this;

  @override
  Element get enclosingElement => firstFragment.enclosingFragment.element;

  @Deprecated('Use enclosingElement instead')
  @override
  Element get enclosingElement2 => enclosingElement;

  @override
  PropertyAccessorFragmentImpl get firstFragment;

  @override
  bool get isExternal => firstFragment.isExternal;

  @override
  PropertyAccessorFragmentImpl get lastFragment {
    return super.lastFragment as PropertyAccessorFragmentImpl;
  }

  @override
  String? get name3 => firstFragment.name2;

  @override
  @trackedDirectly
  PropertyInducingElementImpl? get variable3 {
    globalResultRequirements?.record_propertyAccessorElement_variable(
      element: this,
      name: name3,
    );

    return _variable3;
  }

  set variable3(PropertyInducingElementImpl? value) {
    _variable3 = value;
  }
}

/// Common base class for all analyzer-internal classes that implement
/// `PropertyAccessorElement`.
abstract class PropertyAccessorElementOrMember
    implements ExecutableElementOrMember {
  /// The accessor representing the getter that corresponds to (has the same
  /// name as) this setter, or `null` if this accessor is not a setter or
  /// if there is no corresponding getter.
  PropertyAccessorElementOrMember? get correspondingGetter;

  /// The accessor representing the setter that corresponds to (has the same
  /// name as) this getter, or `null` if this accessor is not a getter or
  /// if there is no corresponding setter.
  PropertyAccessorElementOrMember? get correspondingSetter;

  /// Whether the accessor represents a getter.
  bool get isGetter;

  /// Whether the accessor represents a setter.
  bool get isSetter;

  @override
  TypeImpl get returnType;

  /// The field or top-level variable associated with this accessor.
  ///
  /// If this accessor was explicitly defined (is not synthetic) then the
  /// variable associated with it will be synthetic.
  ///
  /// If this accessor is an augmentation, and [augmentationTarget] is `null`,
  /// the variable is `null`.
  PropertyInducingElementOrMember? get variable2;
}

sealed class PropertyAccessorFragmentImpl extends ExecutableFragmentImpl
    implements PropertyAccessorElementOrMember, PropertyAccessorFragment {
  @override
  final String? name2;

  @override
  int? nameOffset2;

  /// Initialize a newly created property accessor element to have the given
  /// [name] and [offset].
  PropertyAccessorFragmentImpl({
    required this.name2,
    required super.nameOffset,
  });

  /// Initialize a newly created synthetic property accessor element to be
  /// associated with the given [variable].
  PropertyAccessorFragmentImpl.forVariable(
    PropertyInducingFragmentImpl variable,
  ) : name2 = variable.name2,
      super(nameOffset: -1) {
    isAbstract = variable is FieldFragmentImpl && variable.isAbstract;
    isStatic = variable.isStatic;
    isSynthetic = true;
  }

  @override
  PropertyAccessorFragmentImpl? get correspondingGetter;

  @override
  PropertyAccessorFragmentImpl? get correspondingSetter;

  @override
  PropertyAccessorFragmentImpl get declaration => this;

  @override
  PropertyAccessorElementImpl get element;

  @override
  Fragment get enclosingFragment {
    var enclosing = enclosingElement3;
    if (enclosing is InstanceFragment) {
      return enclosing as InstanceFragment;
    } else if (enclosing is LibraryFragmentImpl) {
      return enclosing as LibraryFragment;
    }
    throw UnsupportedError('Not a fragment: ${enclosing.runtimeType}');
  }

  @override
  String get identifier {
    String name = displayName;
    String suffix = isGetter ? "?" : "=";
    return considerCanonicalizeString("$name$suffix");
  }

  /// Set whether this class is abstract.
  set isAbstract(bool isAbstract) {
    setModifier(Modifier.ABSTRACT, isAbstract);
  }

  @override
  ElementKind get kind {
    if (isGetter) {
      return ElementKind.GETTER;
    }
    return ElementKind.SETTER;
  }

  @override
  MetadataImpl get metadata {
    _ensureReadResolution();
    return super.metadata;
  }

  @override
  int get offset {
    if (isSynthetic) {
      var variable = element.variable3!;
      if (variable.isSynthetic) {
        return enclosingFragment.offset;
      }
      return variable.firstFragment.offset;
    }
    return _nameOffset;
  }

  @override
  PropertyInducingFragmentImpl? get variable2 {
    return element.variable3?.firstFragment;
  }

  @override
  PropertyInducingFragment? get variable3 => variable2;

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeExecutableElement(
      this,
      (isGetter ? 'get ' : 'set ') + displayName,
    );
  }
}

/// Implicit getter for a [PropertyInducingFragmentImpl].
class PropertyAccessorFragmentImplImplicitGetter extends GetterFragmentImpl {
  /// Create the implicit getter and bind it to the [property].
  PropertyAccessorFragmentImplImplicitGetter(super.property)
    : super.forVariable();

  @override
  FragmentImpl get enclosingElement3 {
    return variable2.enclosingElement3;
  }

  @override
  bool get hasImplicitReturnType => variable2.hasImplicitType;

  @override
  bool get isGetter => true;

  @override
  String? get name2 => variable2.name2;

  @override
  FragmentImpl get nonSynthetic {
    if (!variable2.isSynthetic) {
      return variable2;
    }
    assert(enclosingElement3 is EnumFragmentImpl);
    return enclosingElement3;
  }

  @override
  int get offset => variable2.offset;

  @override
  TypeImpl get returnType => variable2.type;

  @override
  set returnType(DartType returnType) {
    assert(false); // Should never be called.
  }

  @override
  Version? get sinceSdkVersion => variable2.sinceSdkVersion;

  @override
  FunctionTypeImpl get type {
    return _type ??= FunctionTypeImpl(
      typeFormals: const <TypeParameterFragmentImpl>[],
      parameters: const <FormalParameterElementImpl>[],
      returnType: returnType,
      nullabilitySuffix: NullabilitySuffix.none,
    );
  }

  @override
  set type(FunctionType type) {
    assert(false); // Should never be called.
  }

  @override
  PropertyInducingFragmentImpl get variable2 => super.variable2!;
}

/// Implicit setter for a [PropertyInducingFragmentImpl].
class PropertyAccessorFragmentImplImplicitSetter extends SetterFragmentImpl {
  /// Create the implicit setter and bind it to the [property].
  PropertyAccessorFragmentImplImplicitSetter(super.property)
    : super.forVariable();

  @override
  FragmentImpl get enclosingElement3 {
    return variable2.enclosingElement3;
  }

  @override
  bool get isSetter => true;

  @override
  String? get name2 => variable2.name2;

  @override
  FragmentImpl get nonSynthetic => variable2;

  @override
  int get offset => variable2.offset;

  @override
  List<FormalParameterFragmentImpl> get parameters {
    if (_parameters.isNotEmpty) {
      return _parameters;
    }

    return _parameters = List.generate(
      1,
      (_) => FormalParameterFragmentImplOfImplicitSetter(this),
      growable: false,
    );
  }

  @override
  TypeImpl get returnType => VoidTypeImpl.instance;

  @override
  set returnType(DartType returnType) {
    assert(false); // Should never be called.
  }

  @override
  Version? get sinceSdkVersion => variable2.sinceSdkVersion;

  @override
  FunctionTypeImpl get type {
    return _type ??= FunctionTypeImpl(
      typeFormals: const <TypeParameterFragmentImpl>[],
      parameters: parameters.map((f) => f.asElement2).toList(),
      returnType: returnType,
      nullabilitySuffix: NullabilitySuffix.none,
    );
  }

  @override
  set type(FunctionType type) {
    assert(false); // Should never be called.
  }

  @override
  PropertyInducingFragmentImpl get variable2 => super.variable2!;
}

/// Common base class for all analyzer-internal classes that implement
/// [PropertyInducingElement].
abstract class PropertyInducingElement2OrMember
    implements VariableElement2OrMember, PropertyInducingElement {
  @override
  GetterElement2OrMember? get getter2;

  @override
  MetadataImpl get metadata;

  @override
  SetterElement2OrMember? get setter2;
}

abstract class PropertyInducingElementImpl extends VariableElementImpl
    implements PropertyInducingElement2OrMember, AnnotatableElementImpl {
  @override
  GetterElementImpl? getter2;

  @override
  SetterElementImpl? setter2;

  @override
  PropertyInducingFragmentImpl get firstFragment;

  @override
  List<PropertyInducingFragmentImpl> get fragments {
    return [
      for (
        PropertyInducingFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  bool get hasInitializer {
    return _fragments.any((f) => f.hasInitializer);
  }

  @override
  Element get nonSynthetic {
    if (isSynthetic) {
      if (enclosingElement case EnumElementImpl enclosingElement) {
        // TODO(scheglov): remove 'index'?
        if (name3 == 'index' || name3 == 'values') {
          return enclosingElement;
        }
      }
      return (getter2 ?? setter2)!;
    } else {
      return this;
    }
  }

  @override
  Reference get reference;

  bool get shouldUseTypeForInitializerInference {
    return firstFragment.shouldUseTypeForInitializerInference;
  }

  List<PropertyInducingFragmentImpl> get _fragments;
}

/// Common base class for all analyzer-internal classes that implement
/// `PropertyInducingElement`.
abstract class PropertyInducingElementOrMember
    implements VariableElementOrMember {
  @override
  TypeImpl get type;
}

/// Instances of this class are set for fields and top-level variables
/// to perform top-level type inference during linking.
abstract class PropertyInducingElementTypeInference {
  TypeImpl perform();
}

abstract class PropertyInducingFragmentImpl
    extends NonParameterVariableFragmentImpl
    with AugmentableFragment, DeferredResolutionReadingMixin
    implements PropertyInducingElementOrMember, PropertyInducingFragment {
  @override
  final String? name2;

  @override
  int? nameOffset2;

  @override
  MetadataImpl metadata = MetadataImpl(const []);

  @override
  PropertyInducingFragmentImpl? previousFragment;

  @override
  PropertyInducingFragmentImpl? nextFragment;

  /// This field is set during linking, and performs type inference for
  /// this property. After linking this field is always `null`.
  PropertyInducingElementTypeInference? typeInference;

  /// The error reported during type inference for this variable, or `null` if
  /// this variable is not a subject of type inference, or there was no error.
  TopLevelInferenceError? typeInferenceError;

  /// Initialize a newly created synthetic element to have the given [name] and
  /// [offset].
  PropertyInducingFragmentImpl({
    required this.name2,
    required super.nameOffset,
  }) {
    setModifier(Modifier.SHOULD_USE_TYPE_FOR_INITIALIZER_INFERENCE, true);
  }

  @override
  List<Fragment> get children3 => const [];

  @override
  PropertyInducingElementImpl get element;

  @override
  Fragment get enclosingFragment => enclosingElement3 as Fragment;

  /// The getter associated with this variable.
  ///
  /// If this variable was explicitly defined (is not synthetic) then the
  /// getter associated with it will be synthetic.
  GetterFragmentImpl? get getter => element.getter2?.firstFragment;

  @override
  GetterFragmentImpl? get getter2 => getter;

  /// Return `true` if this variable needs the setter.
  bool get hasSetter {
    if (isConst) {
      return false;
    }

    if (isLate) {
      return !isFinal || !hasInitializer;
    }

    return !isFinal;
  }

  @override
  bool get isConstantEvaluated => true;

  @override
  bool get isLate {
    return hasModifier(Modifier.LATE);
  }

  @override
  LibraryFragment get libraryFragment {
    return enclosingFragment.libraryFragment!;
  }

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  FragmentImpl get nonSynthetic {
    if (isSynthetic) {
      if (enclosingElement3 is EnumFragmentImpl) {
        // TODO(scheglov): remove 'index'?
        if (name2 == 'index' || name2 == 'values') {
          return enclosingElement3;
        }
      }
      return (getter ?? setter)!;
    } else {
      return this;
    }
  }

  /// The setter associated with this variable, or `null` if the variable
  /// is effectively `final` and therefore does not have a setter associated
  /// with it.
  ///
  /// This can happen either because the variable is explicitly defined as
  /// being `final` or because the variable is induced by an explicit getter
  /// that does not have a corresponding setter. If this variable was
  /// explicitly defined (is not synthetic) then the setter associated with
  /// it will be synthetic.
  SetterFragmentImpl? get setter => element.setter2?.firstFragment;

  @override
  SetterFragmentImpl? get setter2 => setter;

  bool get shouldUseTypeForInitializerInference {
    return hasModifier(Modifier.SHOULD_USE_TYPE_FOR_INITIALIZER_INFERENCE);
  }

  set shouldUseTypeForInitializerInference(bool value) {
    setModifier(Modifier.SHOULD_USE_TYPE_FOR_INITIALIZER_INFERENCE, value);
  }

  @override
  TypeImpl get type {
    _ensureReadResolution();
    if (_type != null) return _type!;

    if (isSynthetic) {
      if (element.getter2 case var getter?) {
        return _type = getter.returnType;
      }
      if (element.setter2 case var setter?) {
        if (setter.formalParameters case [var value, ...]) {
          return _type = value.type;
        }
      }
      return _type = DynamicTypeImpl.instance;
    }

    // We must be linking, and the type has not been set yet.
    var type = typeInference!.perform();
    _type = type;
    // TODO(scheglov): We repeat this code.
    if (element.getter2 case var getterElement?) {
      getterElement.returnType = type;
      getterElement.firstFragment.returnType = type;
    }
    if (element.setter2 case var setterElement?) {
      if (setterElement.isSynthetic) {
        setterElement.returnType = VoidTypeImpl.instance;
        setterElement.firstFragment.returnType = VoidTypeImpl.instance;
        (setterElement.formalParameters.single as FormalParameterElementImpl)
            .type = type;
        (setterElement.formalParameters.single as FormalParameterElementImpl)
            .firstFragment
            .type = type;
      }
    }

    shouldUseTypeForInitializerInference = false;
    return _type!;
  }

  @override
  set type(TypeImpl type) {
    super.type = type;
    // Reset cached types of synthetic getters and setters.
    // TODO(scheglov): Consider not caching these types.
    if (!isSynthetic) {
      var getter = this.getter;
      if (getter is PropertyAccessorFragmentImplImplicitGetter) {
        getter._type = null;
      }
      var setter = this.setter;
      if (setter is PropertyAccessorFragmentImplImplicitSetter) {
        setter._type = null;
      }
    }
  }
}

/// Common base class for all analyzer-internal classes that implement
/// [SetterElement].
abstract class SetterElement2OrMember
    implements PropertyAccessorElement2OrMember, SetterElement {
  @override
  SetterElementImpl get baseElement;
}

class SetterElementImpl extends PropertyAccessorElementImpl
    with
        FragmentedExecutableElementMixin<SetterFragmentImpl>,
        FragmentedFunctionTypedElementMixin<SetterFragmentImpl>,
        FragmentedTypeParameterizedElementMixin<SetterFragmentImpl>,
        FragmentedAnnotatableElementMixin<SetterFragmentImpl>,
        FragmentedElementMixin<SetterFragmentImpl>,
        _HasSinceSdkVersionMixin
    implements SetterElement2OrMember {
  @override
  Reference reference;

  @override
  final SetterFragmentImpl firstFragment;

  SetterElementImpl(this.reference, this.firstFragment) {
    reference.element = this;
    SetterFragmentImpl? fragment = firstFragment;
    while (fragment != null) {
      fragment.element = this;
      fragment = fragment.nextFragment;
    }
  }

  @override
  SetterElementImpl get baseElement => this;

  @override
  GetterElement? get correspondingGetter2 {
    return variable3?.getter2;
  }

  @override
  Element get enclosingElement => firstFragment.enclosingFragment.element;

  @Deprecated('Use enclosingElement instead')
  @override
  Element get enclosingElement2 => enclosingElement;

  @override
  List<SetterFragmentImpl> get fragments {
    return [
      for (
        SetterFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  ElementKind get kind => ElementKind.SETTER;

  @override
  SetterFragmentImpl get lastFragment {
    return super.lastFragment as SetterFragmentImpl;
  }

  @override
  String? get lookupName {
    if (name3 case var name?) {
      return '$name=';
    }
    return null;
  }

  @override
  Element get nonSynthetic {
    if (!isSynthetic) {
      return this;
    } else if (variable3 case var variable?) {
      return variable.nonSynthetic;
    }
    throw StateError('Synthetic setter has no variable');
  }

  @override
  Version? get sinceSdkVersion {
    if (isSynthetic) {
      return variable3?.sinceSdkVersion;
    }
    return super.sinceSdkVersion;
  }

  FormalParameterElementImpl get valueFormalParameter {
    return formalParameters.single as FormalParameterElementImpl;
  }

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitSetterElement(this);
  }
}

class SetterFragmentImpl extends PropertyAccessorFragmentImpl
    implements SetterFragment {
  @override
  late SetterElementImpl element;

  @override
  SetterFragmentImpl? previousFragment;

  @override
  SetterFragmentImpl? nextFragment;

  SetterFragmentImpl({required super.name2, required super.nameOffset});

  SetterFragmentImpl.forVariable(super.variable) : super.forVariable();

  @override
  PropertyAccessorFragmentImpl? get correspondingGetter => variable2?.getter;

  @override
  PropertyAccessorFragmentImpl? get correspondingSetter => null;

  @override
  bool get isGetter => false;

  @override
  bool get isSetter => true;

  @override
  String? get lookupName {
    if (name2 case var name?) {
      return '$name=';
    }
    return null;
  }

  FormalParameterFragmentImpl? get valueFormalParameter {
    return formalParameters.singleOrNull;
  }

  void addFragment(SetterFragmentImpl fragment) {
    fragment.element = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }
}

/// A concrete implementation of a [ShowElementCombinator].
class ShowElementCombinatorImpl implements ShowElementCombinator {
  @override
  List<String> shownNames = const [];

  @override
  int offset = 0;

  @override
  int end = -1;

  @override
  String toString() {
    StringBuffer buffer = StringBuffer();
    buffer.write("show ");
    int count = shownNames.length;
    for (int i = 0; i < count; i++) {
      if (i > 0) {
        buffer.write(", ");
      }
      buffer.write(shownNames[i]);
    }
    return buffer.toString();
  }
}

class SuperFormalParameterElementImpl extends FormalParameterElementImpl
    implements SuperFormalParameterElement {
  SuperFormalParameterElementImpl(super.firstFragment);

  @override
  SuperFormalParameterFragmentImpl get firstFragment =>
      super.firstFragment as SuperFormalParameterFragmentImpl;

  @override
  List<SuperFormalParameterFragmentImpl> get fragments {
    return [
      for (
        SuperFormalParameterFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  FormalParameterElementMixin? get superConstructorParameter2 {
    return firstFragment.superConstructorParameter?.asElement2;
  }

  /// Return the index of this super-formal parameter among other super-formals.
  int indexIn(ConstructorElementImpl enclosingElement) {
    return enclosingElement.formalParameters
        .whereType<SuperFormalParameterElementImpl>()
        .toList()
        .indexOf(this);
  }
}

abstract class SuperFormalParameterElementOrMember
    implements ParameterElementMixin {
  /// The associated super-constructor parameter, from the super-constructor
  /// that is referenced by the implicit or explicit super-constructor
  /// invocation.
  ///
  /// Can be `null` for erroneous code - not existing super-constructor,
  /// no corresponding parameter in the super-constructor.
  ParameterElementMixin? get superConstructorParameter;
}

class SuperFormalParameterFragmentImpl extends FormalParameterFragmentImpl
    implements
        SuperFormalParameterElementOrMember,
        SuperFormalParameterFragment {
  /// Initialize a newly created parameter element to have the given [name] and
  /// [nameOffset].
  SuperFormalParameterFragmentImpl({
    required super.nameOffset,
    required super.name2,
    required super.nameOffset2,
    required super.parameterKind,
  });

  @override
  SuperFormalParameterElementImpl get element =>
      super.element as SuperFormalParameterElementImpl;

  /// Super parameters are visible only in the initializer list scope,
  /// and introduce final variables.
  @override
  bool get isFinal => true;

  @override
  bool get isSuperFormal => true;

  @override
  SuperFormalParameterFragmentImpl? get nextFragment =>
      super.nextFragment as SuperFormalParameterFragmentImpl?;

  @override
  SuperFormalParameterFragmentImpl? get previousFragment =>
      super.previousFragment as SuperFormalParameterFragmentImpl?;

  @override
  ParameterElementMixin? get superConstructorParameter {
    var enclosingElement = enclosingElement3;
    if (enclosingElement is ConstructorFragmentImpl) {
      var superConstructor = enclosingElement.superConstructor;
      if (superConstructor != null) {
        var superParameters = superConstructor.parameters;
        if (isNamed) {
          return superParameters.firstWhereOrNull(
            (e) => e.isNamed && e.name2 == name2,
          );
        } else {
          var index = indexIn(enclosingElement);
          var positionalSuperParameters =
              superParameters.where((e) => e.isPositional).toList();
          if (index >= 0 && index < positionalSuperParameters.length) {
            return positionalSuperParameters[index];
          }
        }
      }
    }
    return null;
  }

  /// Return the index of this super-formal parameter among other super-formals.
  int indexIn(ConstructorFragmentImpl enclosingElement) {
    return enclosingElement.parameters
        .whereType<SuperFormalParameterFragmentImpl>()
        .toList()
        .indexOf(this);
  }

  @override
  FormalParameterElementImpl _createElement(
    FormalParameterFragment firstFragment,
  ) => SuperFormalParameterElementImpl(
    firstFragment as FormalParameterFragmentImpl,
  );
}

class TopLevelFunctionElementImpl extends ExecutableElementImpl
    with
        FragmentedExecutableElementMixin<FunctionFragmentImpl>,
        FragmentedFunctionTypedElementMixin<FunctionFragmentImpl>,
        FragmentedTypeParameterizedElementMixin<FunctionFragmentImpl>,
        FragmentedAnnotatableElementMixin<FunctionFragmentImpl>,
        FragmentedElementMixin<FunctionFragmentImpl>,
        _HasSinceSdkVersionMixin
    implements TopLevelFunctionElement {
  @override
  final Reference reference;

  @override
  final TopLevelFunctionFragmentImpl firstFragment;

  TopLevelFunctionElementImpl(this.reference, this.firstFragment) {
    reference.element = this;
    firstFragment.element = this;
  }

  @override
  TopLevelFunctionElementImpl get baseElement => this;

  @override
  LibraryElementImpl get enclosingElement {
    return firstFragment.library;
  }

  @Deprecated('Use enclosingElement instead')
  @override
  LibraryElementImpl get enclosingElement2 => enclosingElement;

  @override
  List<TopLevelFunctionFragmentImpl> get fragments {
    return [
      for (
        TopLevelFunctionFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  bool get isDartCoreIdentical {
    return name3 == 'identical' && library2.isDartCore;
  }

  @override
  bool get isEntryPoint {
    return displayName == TopLevelFunctionElement.MAIN_FUNCTION_NAME;
  }

  @override
  ElementKind get kind => ElementKind.FUNCTION;

  @override
  TopLevelFunctionFragmentImpl get lastFragment {
    return super.lastFragment as TopLevelFunctionFragmentImpl;
  }

  @override
  LibraryElementImpl get library2 {
    return firstFragment.library;
  }

  @override
  String? get name3 => firstFragment.name2;

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitTopLevelFunctionElement(this);
  }
}

/// A concrete implementation of a [TopLevelFunctionFragment].
class TopLevelFunctionFragmentImpl extends FunctionFragmentImpl
    implements TopLevelFunctionFragment {
  /// The element corresponding to this fragment.
  @override
  late TopLevelFunctionElementImpl element;

  @override
  TopLevelFunctionFragmentImpl? previousFragment;

  @override
  TopLevelFunctionFragmentImpl? nextFragment;

  TopLevelFunctionFragmentImpl({
    required super.name2,
    required super.nameOffset,
  });

  @override
  LibraryFragmentImpl get enclosingElement3 =>
      super.enclosingElement3 as LibraryFragmentImpl;

  @override
  set enclosingElement3(covariant LibraryFragmentImpl element);

  void addFragment(TopLevelFunctionFragmentImpl fragment) {
    fragment.element = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }
}

class TopLevelVariableElementImpl extends PropertyInducingElementImpl
    with
        FragmentedAnnotatableElementMixin<TopLevelVariableFragmentImpl>,
        FragmentedElementMixin<TopLevelVariableFragmentImpl>,
        _HasSinceSdkVersionMixin
    implements TopLevelVariableElement {
  @override
  final Reference reference;

  @override
  final TopLevelVariableFragmentImpl firstFragment;

  TopLevelVariableElementImpl(this.reference, this.firstFragment) {
    reference.element = this;
    firstFragment.element = this;
  }

  @override
  TopLevelVariableElement get baseElement => this;

  @override
  LibraryElementImpl get enclosingElement => firstFragment.library;

  @Deprecated('Use enclosingElement instead')
  @override
  LibraryElement get enclosingElement2 => enclosingElement;

  @override
  List<TopLevelVariableFragmentImpl> get fragments {
    return [
      for (
        TopLevelVariableFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  @override
  bool get hasImplicitType => firstFragment.hasImplicitType;

  @override
  bool get isConst => firstFragment.isConst;

  @override
  bool get isExternal => firstFragment.isExternal;

  @override
  bool get isFinal => firstFragment.isFinal;

  @override
  bool get isLate => firstFragment.isLate;

  @override
  bool get isStatic => firstFragment.isStatic;

  @override
  ElementKind get kind => ElementKind.TOP_LEVEL_VARIABLE;

  @override
  LibraryElement get library2 {
    return firstFragment.libraryFragment.element;
  }

  @override
  String? get name3 => firstFragment.name2;

  @override
  TypeImpl get type => firstFragment.type;

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitTopLevelVariableElement(this);
  }

  @override
  DartObject? computeConstantValue() => firstFragment.computeConstantValue();
}

class TopLevelVariableFragmentImpl extends PropertyInducingFragmentImpl
    with ConstVariableFragment
    implements TopLevelVariableFragment {
  @override
  late TopLevelVariableElementImpl element;

  /// Initialize a newly created synthetic top-level variable element to have
  /// the given [name] and [offset].
  TopLevelVariableFragmentImpl({
    required super.name2,
    required super.nameOffset,
  });

  @override
  ExpressionImpl? get constantInitializer {
    _ensureReadResolution();
    return super.constantInitializer;
  }

  @override
  TopLevelVariableFragmentImpl get declaration => this;

  bool get isExternal {
    return hasModifier(Modifier.EXTERNAL);
  }

  @override
  bool get isStatic => true;

  @override
  ElementKind get kind => ElementKind.TOP_LEVEL_VARIABLE;

  @override
  LibraryElementImpl get library2 => library;

  @override
  LibraryFragmentImpl get libraryFragment => enclosingUnit;

  @override
  MetadataImpl get metadata {
    _ensureReadResolution();
    return super.metadata;
  }

  @override
  TopLevelVariableFragmentImpl? get nextFragment =>
      super.nextFragment as TopLevelVariableFragmentImpl?;

  @override
  TopLevelVariableFragmentImpl? get previousFragment =>
      super.previousFragment as TopLevelVariableFragmentImpl?;

  void addFragment(TopLevelVariableFragmentImpl fragment) {
    fragment.element = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }
}

class TypeAliasElementImpl extends TypeDefiningElementImpl
    with
        FragmentedAnnotatableElementMixin<TypeAliasFragment>,
        FragmentedElementMixin<TypeAliasFragment>,
        DeferredResolutionReadingMixin,
        _HasSinceSdkVersionMixin
    implements AnnotatableElementImpl, TypeAliasElement {
  @override
  final Reference reference;

  @override
  final TypeAliasFragmentImpl firstFragment;

  TypeAliasElementImpl(this.reference, this.firstFragment) {
    reference.element = this;
    firstFragment.element = this;
  }

  @override
  Element? get aliasedElement2 {
    switch (firstFragment.aliasedElement) {
      case InstanceFragment instance:
        return instance.element;
      case GenericFunctionTypeFragment instance:
        return instance.element;
    }
    return null;
  }

  @override
  TypeImpl get aliasedType => firstFragment.aliasedType;

  set aliasedType(TypeImpl value) {
    firstFragment.aliasedType = value;
  }

  /// The aliased type, might be `null` if not yet linked.
  TypeImpl? get aliasedTypeRaw => firstFragment.aliasedTypeRaw;

  @override
  TypeAliasElementImpl get baseElement => this;

  @override
  LibraryElement get enclosingElement =>
      firstFragment.library as LibraryElement;

  @Deprecated('Use enclosingElement instead')
  @override
  LibraryElement get enclosingElement2 => enclosingElement;

  @override
  List<TypeAliasFragmentImpl> get fragments {
    return [
      for (
        TypeAliasFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  /// Whether this alias is a "proper rename" of [aliasedType], as defined in
  /// the constructor-tearoffs specification.
  bool get isProperRename {
    var aliasedType_ = aliasedType;
    if (aliasedType_ is! InterfaceTypeImpl) {
      return false;
    }
    var typeParameters = typeParameters2;
    var aliasedClass = aliasedType_.element3;
    var typeArguments = aliasedType_.typeArguments;
    var typeParameterCount = typeParameters.length;
    if (typeParameterCount != aliasedClass.typeParameters2.length) {
      return false;
    }
    for (var i = 0; i < typeParameterCount; i++) {
      var bound = typeParameters[i].bound ?? DynamicTypeImpl.instance;
      var aliasedBound =
          aliasedClass.typeParameters2[i].bound ??
          library2.typeProvider.dynamicType;
      if (!library2.typeSystem.isSubtypeOf(bound, aliasedBound) ||
          !library2.typeSystem.isSubtypeOf(aliasedBound, bound)) {
        return false;
      }
      var typeArgument = typeArguments[i];
      if (typeArgument is TypeParameterType &&
          typeParameters[i] != typeArgument.element3) {
        return false;
      }
    }
    return true;
  }

  @override
  bool get isSimplyBounded => firstFragment.isSimplyBounded;

  set isSimplyBounded(bool value) {
    for (var fragment in fragments) {
      fragment.isSimplyBounded = value;
    }
  }

  @override
  ElementKind get kind => ElementKind.TYPE_ALIAS;

  @override
  LibraryElementImpl get library2 {
    return firstFragment.library;
  }

  @override
  String? get name3 => firstFragment.name2;

  @override
  List<TypeParameterElementImpl> get typeParameters2 =>
      firstFragment.typeParameters2
          .map((fragment) => fragment.element)
          .toList();

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitTypeAliasElement(this);
  }

  @override
  TypeImpl instantiate({
    required List<DartType> typeArguments,
    required NullabilitySuffix nullabilitySuffix,
  }) {
    return instantiateImpl(
      typeArguments: typeArguments.cast<TypeImpl>(),
      nullabilitySuffix: nullabilitySuffix,
    );
  }

  TypeImpl instantiateImpl({
    required List<TypeImpl> typeArguments,
    required NullabilitySuffix nullabilitySuffix,
  }) {
    if (firstFragment.hasSelfReference) {
      if (firstFragment.isNonFunctionTypeAliasesEnabled) {
        return DynamicTypeImpl.instance;
      } else {
        return _errorFunctionType(nullabilitySuffix);
      }
    }

    var substitution = Substitution.fromPairs2(typeParameters2, typeArguments);
    var type = substitution.substituteType(aliasedType);

    var resultNullability =
        type.nullabilitySuffix == NullabilitySuffix.question
            ? NullabilitySuffix.question
            : nullabilitySuffix;

    if (type is FunctionTypeImpl) {
      return FunctionTypeImpl(
        typeFormals: type.typeFormals,
        parameters: type.parameters,
        returnType: type.returnType,
        nullabilitySuffix: resultNullability,
        alias: InstantiatedTypeAliasElementImpl(
          element2: this,
          typeArguments: typeArguments,
        ),
      );
    } else if (type is InterfaceTypeImpl) {
      return InterfaceTypeImpl(
        element: type.element3,
        typeArguments: type.typeArguments,
        nullabilitySuffix: resultNullability,
        alias: InstantiatedTypeAliasElementImpl(
          element2: this,
          typeArguments: typeArguments,
        ),
      );
    } else if (type is RecordTypeImpl) {
      return RecordTypeImpl(
        positionalFields: type.positionalFields,
        namedFields: type.namedFields,
        nullabilitySuffix: resultNullability,
        alias: InstantiatedTypeAliasElementImpl(
          element2: this,
          typeArguments: typeArguments,
        ),
      );
    } else if (type is TypeParameterTypeImpl) {
      return TypeParameterTypeImpl(
        element3: type.element3,
        nullabilitySuffix: resultNullability,
        alias: InstantiatedTypeAliasElementImpl(
          element2: this,
          typeArguments: typeArguments,
        ),
      );
    } else {
      return type.withNullability(resultNullability);
    }
  }

  FunctionTypeImpl _errorFunctionType(NullabilitySuffix nullabilitySuffix) {
    return FunctionTypeImpl(
      typeFormals: const [],
      parameters: const [],
      returnType: DynamicTypeImpl.instance,
      nullabilitySuffix: nullabilitySuffix,
    );
  }
}

/// An element that represents [GenericTypeAlias].
///
/// Clients may not extend, implement or mix-in this class.
class TypeAliasFragmentImpl extends _ExistingFragmentImpl
    with
        AugmentableFragment,
        DeferredResolutionReadingMixin,
        TypeParameterizedFragmentMixin
    implements TypeAliasFragment {
  @override
  final String? name2;

  @override
  int? nameOffset2;

  @override
  TypeAliasFragmentImpl? previousFragment;

  @override
  TypeAliasFragmentImpl? nextFragment;

  /// Is `true` if the element has direct or indirect reference to itself
  /// from anywhere except a class element or type parameter bounds.
  bool hasSelfReference = false;

  bool isFunctionTypeAliasBased = false;

  FragmentImpl? _aliasedElement;
  TypeImpl? _aliasedType;

  @override
  late TypeAliasElementImpl element;

  TypeAliasFragmentImpl({required this.name2, required super.nameOffset});

  /// If the aliased type has structure, return the corresponding element.
  /// For example it could be [GenericFunctionTypeElement].
  ///
  /// If there is no structure, return `null`.
  FragmentImpl? get aliasedElement {
    _ensureReadResolution();
    return _aliasedElement;
  }

  set aliasedElement(FragmentImpl? aliasedElement) {
    _aliasedElement = aliasedElement;
    aliasedElement?.enclosingElement3 = this;
  }

  /// The aliased type.
  ///
  /// If non-function type aliases feature is enabled for the enclosing library,
  /// this type might be just anything. If the feature is disabled, return
  /// a [FunctionType].
  TypeImpl get aliasedType {
    _ensureReadResolution();
    return _aliasedType!;
  }

  set aliasedType(DartType rawType) {
    // TODO(paulberry): eliminate this cast by changing the type of the
    // `rawType` parameter.
    _aliasedType = rawType as TypeImpl;
  }

  /// The aliased type, might be `null` if not yet linked.
  TypeImpl? get aliasedTypeRaw => _aliasedType;

  @override
  List<Fragment> get children3 => const [];

  @override
  String get displayName => name2 ?? '';

  @override
  LibraryFragmentImpl get enclosingElement3 =>
      super.enclosingElement3 as LibraryFragmentImpl;

  @override
  LibraryFragment? get enclosingFragment =>
      enclosingElement3 as LibraryFragment;

  @override
  bool get isSimplyBounded {
    return hasModifier(Modifier.SIMPLY_BOUNDED);
  }

  set isSimplyBounded(bool isSimplyBounded) {
    setModifier(Modifier.SIMPLY_BOUNDED, isSimplyBounded);
  }

  @override
  ElementKind get kind {
    if (isNonFunctionTypeAliasesEnabled) {
      return ElementKind.TYPE_ALIAS;
    } else {
      return ElementKind.FUNCTION_TYPE_ALIAS;
    }
  }

  @override
  MetadataImpl get metadata {
    _ensureReadResolution();
    return super.metadata;
  }

  @override
  int get offset => nameOffset;

  void addFragment(TypeAliasFragmentImpl fragment) {
    fragment.element = element;
    fragment.previousFragment = this;
    nextFragment = fragment;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeTypeAliasElement(this);
  }
}

abstract class TypeDefiningElementImpl extends ElementImpl
    implements TypeDefiningElement {}

class TypeParameterElementImpl extends TypeDefiningElementImpl
    with
        FragmentedAnnotatableElementMixin<TypeParameterFragment>,
        FragmentedElementMixin<TypeParameterFragment>,
        _NonTopLevelVariableOrParameter
    implements TypeParameterElement, SharedTypeParameter {
  @override
  final TypeParameterFragmentImpl firstFragment;

  @override
  final String? name3;

  TypeParameterElementImpl({required this.firstFragment, required this.name3}) {
    TypeParameterFragmentImpl? fragment = firstFragment;
    while (fragment != null) {
      fragment.element = this;
      fragment = fragment.nextFragment;
    }
  }

  @override
  TypeParameterElement get baseElement => this;

  @override
  TypeImpl? get bound => firstFragment.bound;

  set bound(TypeImpl? value) {
    firstFragment.bound = value;
  }

  @override
  TypeImpl? get boundShared => bound;

  /// The default value of the type parameter. It is used to provide the
  /// corresponding missing type argument in type annotations and as the
  /// fall-back type value in type inference.
  TypeImpl? get defaultType => firstFragment.defaultType;

  @override
  List<TypeParameterFragmentImpl> get fragments {
    return [
      for (
        TypeParameterFragmentImpl? fragment = firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      )
        fragment,
    ];
  }

  bool get isLegacyCovariant => firstFragment.isLegacyCovariant;

  @override
  ElementKind get kind => ElementKind.TYPE_PARAMETER;

  @override
  LibraryElementImpl? get library2 => firstFragment.library;

  shared.Variance get variance => firstFragment.variance;

  set variance(shared.Variance? value) {
    firstFragment.variance = value;
  }

  @override
  FragmentImpl? get _enclosingFunction => firstFragment.enclosingElement3;

  @override
  T? accept2<T>(ElementVisitor2<T> visitor) {
    return visitor.visitTypeParameterElement(this);
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeTypeParameter2(this);
  }

  @override
  TypeParameterTypeImpl instantiate({
    required NullabilitySuffix nullabilitySuffix,
  }) {
    return TypeParameterTypeImpl(
      element3: this,
      nullabilitySuffix: nullabilitySuffix,
    );
  }

  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {
    for (var child in children2) {
      child.accept2(visitor);
    }
  }
}

class TypeParameterFragmentImpl extends FragmentImpl
    implements AnnotatableFragmentImpl, TypeParameterFragment {
  @override
  final String? name2;

  @override
  int? nameOffset2;

  @override
  MetadataImpl metadata = MetadataImpl(const []);

  /// The default value of the type parameter. It is used to provide the
  /// corresponding missing type argument in type annotations and as the
  /// fall-back type value in type inference.
  TypeImpl? defaultType;

  /// The type representing the bound associated with this parameter, or `null`
  /// if this parameter does not have an explicit bound.
  TypeImpl? _bound;

  /// The value representing the variance modifier keyword, or `null` if
  /// there is no explicit variance modifier, meaning legacy covariance.
  shared.Variance? _variance;

  /// The element corresponding to this fragment.
  TypeParameterElementImpl? _element;

  /// Initialize a newly created method element to have the given [name] and
  /// [offset].
  TypeParameterFragmentImpl({required this.name2, required super.nameOffset});

  /// Initialize a newly created synthetic type parameter element to have the
  /// given [name], and with [isSynthetic] set to `true`.
  TypeParameterFragmentImpl.synthetic({required this.name2})
    : super(nameOffset: -1) {
    isSynthetic = true;
  }

  /// The type representing the bound associated with this parameter, or `null`
  /// if this parameter does not have an explicit bound. Being able to
  /// distinguish between an implicit and explicit bound is needed by the
  /// instantiate to bounds algorithm.
  TypeImpl? get bound {
    return _bound;
  }

  set bound(DartType? bound) {
    // TODO(paulberry): Change the type of the parameter `bound` so that this
    // cast isn't needed.
    _bound = bound as TypeImpl?;
    if (_element case var element?) {
      if (!identical(element.bound, bound)) {
        element.bound = bound;
      }
    }
  }

  @override
  List<Fragment> get children3 => const [];

  @override
  TypeParameterFragmentImpl get declaration => this;

  @override
  String get displayName => name2 ?? '';

  @override
  TypeParameterElementImpl get element {
    if (_element != null) {
      return _element!;
    }
    var firstFragment = this;
    var previousFragment = firstFragment.previousFragment;
    while (previousFragment != null) {
      firstFragment = previousFragment;
      previousFragment = firstFragment.previousFragment;
    }
    // As a side-effect of creating the element, all of the fragments in the
    // chain will have their `_element` set to the newly created element.
    return TypeParameterElementImpl(
      firstFragment: firstFragment,
      name3: firstFragment.name2,
    );
  }

  set element(TypeParameterElementImpl element) {
    _element = element;
  }

  @override
  FragmentImpl? get enclosingFragment => enclosingElement3;

  bool get isLegacyCovariant {
    return _variance == null;
  }

  @override
  ElementKind get kind => ElementKind.TYPE_PARAMETER;

  @override
  LibraryElementImpl? get library {
    var library = libraryFragment?.element;
    return library as LibraryElementImpl?;
  }

  @override
  LibraryFragment? get libraryFragment {
    return enclosingFragment?.libraryFragment;
  }

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  @override
  // TODO(augmentations): Support chaining between the fragments.
  TypeParameterFragmentImpl? get nextFragment => null;

  @override
  int get offset => nameOffset;

  @override
  // TODO(augmentations): Support chaining between the fragments.
  TypeParameterFragmentImpl? get previousFragment => null;

  shared.Variance get variance {
    return _variance ?? shared.Variance.covariant;
  }

  set variance(shared.Variance? newVariance) => _variance = newVariance;

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeTypeParameter(this);
  }

  /// Computes the variance of the type parameters in the [type].
  shared.Variance computeVarianceInType(DartType type) {
    if (type is TypeParameterTypeImpl) {
      if (type.element3 == element) {
        return shared.Variance.covariant;
      } else {
        return shared.Variance.unrelated;
      }
    } else if (type is InterfaceTypeImpl) {
      var result = shared.Variance.unrelated;
      for (int i = 0; i < type.typeArguments.length; ++i) {
        var argument = type.typeArguments[i];
        var parameter = type.element3.typeParameters2[i];

        var parameterVariance = parameter.variance;
        result = result.meet(
          parameterVariance.combine(computeVarianceInType(argument)),
        );
      }
      return result;
    } else if (type is FunctionType) {
      var result = computeVarianceInType(type.returnType);

      for (var parameter in type.typeParameters) {
        // If [parameter] is referenced in the bound at all, it makes the
        // variance of [parameter] in the entire type invariant.  The invocation
        // of [computeVariance] below is made to simply figure out if [variable]
        // occurs in the bound.
        var bound = parameter.bound;
        if (bound != null && !computeVarianceInType(bound).isUnrelated) {
          result = shared.Variance.invariant;
        }
      }

      for (var parameter in type.formalParameters) {
        result = result.meet(
          shared.Variance.contravariant.combine(
            computeVarianceInType(parameter.type),
          ),
        );
      }
      return result;
    }
    return shared.Variance.unrelated;
  }

  /// Creates the [TypeParameterType] with the given [nullabilitySuffix] for
  /// this type parameter.
  TypeParameterTypeImpl instantiate({
    required NullabilitySuffix nullabilitySuffix,
  }) {
    return element.instantiate(nullabilitySuffix: nullabilitySuffix);
  }
}

abstract class TypeParameterizedElementImpl extends ElementImpl
    implements TypeParameterizedElement {}

/// Mixin representing an element which can have type parameters.
mixin TypeParameterizedFragmentMixin on FragmentImpl
    implements
        _ExistingFragmentImpl,
        AnnotatableFragmentImpl,
        TypeParameterizedFragment {
  List<TypeParameterFragmentImpl> _typeParameters = const [];

  @override
  MetadataImpl metadata = MetadataImpl(const []);

  /// If the element defines a type, indicates whether the type may safely
  /// appear without explicit type parameters as the bounds of a type parameter
  /// declaration.
  ///
  /// If the element does not define a type, returns `true`.
  bool get isSimplyBounded => true;

  @override
  LibraryFragmentImpl get libraryFragment => enclosingUnit;

  @Deprecated('Use metadata instead')
  @override
  MetadataImpl get metadata2 => metadata;

  /// The type parameters declared by this element directly.
  ///
  /// This does not include type parameters that are declared by any enclosing
  /// elements.
  List<TypeParameterFragmentImpl> get typeParameters {
    _ensureReadResolution();
    return _typeParameters;
  }

  set typeParameters(List<TypeParameterFragmentImpl> typeParameters) {
    for (var typeParameter in typeParameters) {
      typeParameter.enclosingElement3 = this;
    }
    _typeParameters = typeParameters;
  }

  @override
  List<TypeParameterFragmentImpl> get typeParameters2 =>
      typeParameters.cast<TypeParameterFragmentImpl>();

  List<TypeParameterFragmentImpl> get typeParameters_unresolved {
    return _typeParameters;
  }

  void _ensureReadResolution();
}

/// Common base class for all analyzer-internal classes that implement
/// `VariableElement2`.
abstract class VariableElement2OrMember implements VariableElement {
  @override
  TypeImpl get type;
}

abstract class VariableElementImpl extends ElementImpl
    implements VariableElement2OrMember {
  ConstantInitializerImpl? _constantInitializer;

  @override
  ConstantInitializer? get constantInitializer2 {
    if (_constantInitializer case var result?) {
      return result;
    }

    for (var fragment in fragments.reversed) {
      if (fragment.initializer case ExpressionImpl expression) {
        return _constantInitializer = ConstantInitializerImpl(
          fragment: fragment as VariableFragmentImpl,
          expression: expression,
        );
      }
    }

    return null;
  }

  void resetConstantInitializer() {
    _constantInitializer = null;
  }

  @override
  void visitChildren2<T>(ElementVisitor2<T> visitor) {
    for (var child in children2) {
      child.accept2(visitor);
    }
  }
}

/// Common base class for all analyzer-internal classes that implement
/// `VariableElement`.
abstract class VariableElementOrMember
    implements FragmentOrMember, Annotatable, ConstantEvaluationTarget {
  @override
  VariableFragmentImpl get declaration;

  /// Whether the variable element did not have an explicit type specified
  /// for it.
  bool get hasImplicitType;

  /// Whether the variable was declared with the 'const' modifier.
  bool get isConst;

  /// Whether the variable was declared with the 'final' modifier.
  ///
  /// Variables that are declared with the 'const' modifier will return `false`
  /// even though they are implicitly final.
  bool get isFinal;

  /// Whether the variable uses late evaluation semantics.
  ///
  /// This will always return `false` unless the experiment 'non-nullable' is
  /// enabled.
  bool get isLate;

  /// Whether the element is a static variable, as per section 8 of the Dart
  /// Language Specification:
  ///
  /// > A static variable is a variable that is not associated with a particular
  /// > instance, but rather with an entire library or class. Static variables
  /// > include library variables and class variables. Class variables are
  /// > variables whose declaration is immediately nested inside a class
  /// > declaration and includes the modifier static. A library variable is
  /// > implicitly static.
  bool get isStatic;

  /// The declared type of this variable.
  TypeImpl get type;

  /// Returns a representation of the value of this variable, forcing the value
  /// to be computed if it had not previously been computed, or `null` if either
  /// this variable was not declared with the 'const' modifier or if the value
  /// of this variable could not be computed because of errors.
  DartObject? computeConstantValue();
}

abstract class VariableFragmentImpl extends FragmentImpl
    implements
        VariableElementOrMember,
        AnnotatableFragmentImpl,
        VariableFragment {
  /// The type of this variable.
  TypeImpl? _type;

  /// Initialize a newly created variable element to have the given [name] and
  /// [offset].
  VariableFragmentImpl({required super.nameOffset});

  /// If this element represents a constant variable, and it has an initializer,
  /// a copy of the initializer for the constant.  Otherwise `null`.
  ///
  /// Note that in correct Dart code, all constant variables must have
  /// initializers.  However, analyzer also needs to handle incorrect Dart code,
  /// in which case there might be some constant variables that lack
  /// initializers.
  ExpressionImpl? get constantInitializer => null;

  @override
  VariableFragmentImpl get declaration => this;

  @override
  String get displayName => name2 ?? '';

  @override
  VariableElementImpl get element;

  /// Return the result of evaluating this variable's initializer as a
  /// compile-time constant expression, or `null` if this variable is not a
  /// 'const' variable, if it does not have an initializer, or if the
  /// compilation unit containing the variable has not been resolved.
  Constant? get evaluationResult => null;

  /// Set the result of evaluating this variable's initializer as a compile-time
  /// constant expression to the given [result].
  set evaluationResult(Constant? result) {
    throw StateError("Invalid attempt to set a compile-time constant result");
  }

  @override
  bool get hasImplicitType {
    return hasModifier(Modifier.IMPLICIT_TYPE);
  }

  /// Set whether this variable element has an implicit type.
  set hasImplicitType(bool hasImplicitType) {
    setModifier(Modifier.IMPLICIT_TYPE, hasImplicitType);
  }

  @override
  ExpressionImpl? get initializer {
    return constantInitializer;
  }

  /// Set whether this variable is abstract.
  set isAbstract(bool isAbstract) {
    setModifier(Modifier.ABSTRACT, isAbstract);
  }

  @override
  bool get isConst {
    return hasModifier(Modifier.CONST);
  }

  /// Set whether this variable is const.
  set isConst(bool isConst) {
    setModifier(Modifier.CONST, isConst);
  }

  @override
  bool get isConstantEvaluated => true;

  /// Set whether this variable is external.
  set isExternal(bool isExternal) {
    setModifier(Modifier.EXTERNAL, isExternal);
  }

  @override
  bool get isFinal {
    return hasModifier(Modifier.FINAL);
  }

  /// Set whether this variable is final.
  set isFinal(bool isFinal) {
    setModifier(Modifier.FINAL, isFinal);
  }

  /// Set whether this variable is late.
  set isLate(bool isLate) {
    setModifier(Modifier.LATE, isLate);
  }

  @override
  bool get isStatic => hasModifier(Modifier.STATIC);

  set isStatic(bool isStatic) {
    setModifier(Modifier.STATIC, isStatic);
  }

  @override
  int get offset => nameOffset;

  @override
  TypeImpl get type => _type!;

  set type(TypeImpl type) {
    _type = type;
  }

  @override
  void appendTo(ElementDisplayStringBuilder builder) {
    builder.writeVariableElement(this);
  }

  @override
  DartObject? computeConstantValue() => null;
}

mixin WrappedElementMixin implements ElementImpl {
  @override
  bool get isSynthetic => _wrappedElement.isSynthetic;

  @override
  ElementKind get kind => _wrappedElement.kind;

  @override
  String? get name3 => _wrappedElement.name2;

  FragmentImpl get _wrappedElement;

  @override
  String displayString2({
    bool multiline = false,
    bool preferTypeAlias = false,
  }) => _wrappedElement.getDisplayString(
    multiline: multiline,
    preferTypeAlias: preferTypeAlias,
  );
}

abstract class _ExistingFragmentImpl extends FragmentImpl
    with _HasLibraryMixin {
  _ExistingFragmentImpl({required super.nameOffset});
}

/// An element that can be declared in multiple fragments.
abstract class _Fragmented<E extends Fragment> {
  E get firstFragment;
}

mixin _HasLibraryMixin on FragmentImpl {
  @override
  LibraryElementImpl get library {
    var thisFragment = this as Fragment;
    var enclosingFragment = thisFragment.enclosingFragment!;
    var libraryFragment = enclosingFragment.libraryFragment;
    libraryFragment as LibraryFragmentImpl;
    return libraryFragment.element;
  }

  @override
  Source get librarySource => library.source;

  @override
  Source get source => enclosingElement3!.source!;
}

mixin _HasSinceSdkVersionMixin on ElementImpl, Annotatable
    implements HasSinceSdkVersion {
  /// Cached values for [sinceSdkVersion].
  ///
  /// Only very few elements have `@Since()` annotations, so instead of adding
  /// an instance field to [ElementImpl], we attach this information this way.
  /// We ask it only when [Modifier.HAS_SINCE_SDK_VERSION_VALUE] is `true`, so
  /// don't pay for a hash lookup when we know that the result is `null`.
  static final Expando<Version> _sinceSdkVersion = Expando<Version>();

  @override
  Version? get sinceSdkVersion {
    if (!hasModifier(Modifier.HAS_SINCE_SDK_VERSION_COMPUTED)) {
      setModifier(Modifier.HAS_SINCE_SDK_VERSION_COMPUTED, true);
      var result = SinceSdkVersionComputer().compute(this);
      if (result != null) {
        _sinceSdkVersion[this] = result;
        setModifier(Modifier.HAS_SINCE_SDK_VERSION_VALUE, true);
      }
    }
    if (hasModifier(Modifier.HAS_SINCE_SDK_VERSION_VALUE)) {
      return _sinceSdkVersion[this];
    }
    return null;
  }
}

mixin _NonTopLevelVariableOrParameter on Element {
  @override
  Element? get enclosingElement {
    // TODO(dantup): Can we simplify this code and inline it into each class?
    return _enclosingFunction?.element;
  }

  @Deprecated('Use enclosingElement instead')
  @override
  Element? get enclosingElement2 => enclosingElement;

  FragmentImpl? get _enclosingFunction;
}

/// Instances of [List]s that are used as "not yet computed" values, they
/// must be not `null`, and not identical to `const <T>[]`.
class _Sentinel {
  static final List<ConstructorFragmentImpl> constructorElement =
      List.unmodifiable([]);
  static final List<FieldFragmentImpl> fieldElement = List.unmodifiable([]);
  static final List<GetterFragmentImpl> getterElement = List.unmodifiable([]);
  static final List<LibraryExportImpl> libraryExport = List.unmodifiable([]);
  static final List<LibraryImportImpl> libraryImport = List.unmodifiable([]);
  static final List<MethodFragmentImpl> methodElement = List.unmodifiable([]);
  static final List<SetterFragmentImpl> setterElement = List.unmodifiable([]);
}

extension on Fragment {
  /// The content of the documentation comment (including delimiters) for this
  /// fragment.
  ///
  /// Returns `null` if the receiver does not have or does not support
  /// documentation.
  String? get documentationCommentOrNull {
    return switch (this) {
      Annotatable(:var documentationComment) => documentationComment,
      _ => null,
    };
  }
}
