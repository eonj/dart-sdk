// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/member.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:meta/meta.dart';

class MockLibraryImportElement implements Element, PrefixFragment {
  final LibraryImportImpl import;

  MockLibraryImportElement(LibraryImport import)
    : import = import as LibraryImportImpl;

  @override
  LibraryElement get enclosingElement => library2;

  @override
  ElementKind get kind => ElementKind.IMPORT;

  @override
  LibraryElementImpl get library2 => libraryFragment.element;

  @override
  LibraryFragmentImpl get libraryFragment => import.libraryFragment;

  @override
  String? get name3 => import.prefix2?.name2;

  @override
  noSuchMethod(invocation) => super.noSuchMethod(invocation);
}

extension BindPatternVariableElementImpl2Extension
    on BindPatternVariableElementImpl {
  BindPatternVariableFragmentImpl get asElement {
    return firstFragment;
  }
}

extension BindPatternVariableElementImplExtension
    on BindPatternVariableFragmentImpl {
  BindPatternVariableElementImpl get asElement2 {
    return element;
  }
}

extension ClassElementImpl2Extension on ClassElementImpl {
  ClassFragmentImpl get asElement {
    return firstFragment;
  }
}

extension ClassElementImplExtension on ClassFragmentImpl {
  ClassElementImpl get asElement2 {
    return element;
  }
}

extension CompilationUnitElementImplExtension on LibraryFragmentImpl {
  /// Returns this library fragment, and all its enclosing fragments.
  List<LibraryFragmentImpl> get withEnclosing {
    var result = <LibraryFragmentImpl>[];
    var current = this;
    while (true) {
      result.add(current);
      if (current.enclosingElement3 case var enclosing?) {
        current = enclosing;
      } else {
        break;
      }
    }
    return result;
  }
}

extension ConstructorElementImpl2Extension on ConstructorElementImpl {
  ConstructorFragmentImpl get asElement {
    return lastFragment;
  }
}

extension ConstructorElementImplExtension on ConstructorFragmentImpl {
  ConstructorElementImpl get asElement2 {
    return element;
  }
}

extension ConstructorElementMixin2Extension on ConstructorElementMixin2 {
  ConstructorElementMixin get asElement {
    if (this case ConstructorMember member) {
      return member;
    }
    return (this as ConstructorElementImpl).lastFragment;
  }
}

extension ConstructorElementMixinExtension on ConstructorElementMixin {
  ConstructorElementMixin2 get asElement2 {
    return switch (this) {
      ConstructorFragmentImpl(:var element) => element,
      ConstructorMember member => member,
      _ => throw UnsupportedError('Unsupported type: $runtimeType'),
    };
  }
}

extension Element2Extension on Element {
  /// Whether the element is effectively [internal].
  bool get isInternal {
    if (this case Annotatable annotatable) {
      if (annotatable.metadata.hasInternal) {
        return true;
      }
    }
    if (this case PropertyAccessorElement accessor) {
      var variable = accessor.variable3;
      if (variable != null && variable.metadata.hasInternal) {
        return true;
      }
    }
    return false;
  }

  /// Whether the element is effectively [protected].
  bool get isProtected {
    var self = this;
    if (self is PropertyAccessorElement &&
        self.enclosingElement is InterfaceElement) {
      if (self.metadata.hasProtected) {
        return true;
      }
      var variable = self.variable3;
      if (variable != null && variable.metadata.hasProtected) {
        return true;
      }
    }
    if (self is MethodElement &&
        self.enclosingElement is InterfaceElement &&
        self.metadata.hasProtected) {
      return true;
    }
    return false;
  }

  /// Whether the element is effectively [visibleForTesting].
  bool get isVisibleForTesting {
    if (this case Annotatable annotatable) {
      if (annotatable.metadata.hasVisibleForTesting) {
        return true;
      }
    }
    if (this case PropertyAccessorElement accessor) {
      var variable = accessor.variable3;
      if (variable != null && variable.metadata.hasVisibleForTesting) {
        return true;
      }
    }
    return false;
  }

  List<ElementAnnotation> get metadataAnnotations {
    if (this case Annotatable annotatable) {
      return annotatable.metadata.annotations;
    }
    return [];
  }
}

extension ElementImplExtension on FragmentImpl {
  FragmentImpl? get enclosingElementImpl => enclosingElement3;
}

extension ElementOrNullExtension on FragmentImpl? {
  Element? get asElement2 {
    var self = this;
    if (self == null) {
      return null;
    } else if (self is DynamicFragmentImpl) {
      return DynamicElementImpl.instance;
    } else if (self is ExtensionFragmentImpl) {
      return (self as ExtensionFragment).element;
    } else if (self is ExecutableMember) {
      return self as ExecutableElement;
    } else if (self is FieldMember) {
      return self as FieldElement;
    } else if (self is FieldFragmentImpl) {
      return (self as FieldFragment).element;
    } else if (self is FunctionFragmentImpl) {
      return (self as Fragment).element;
    } else if (self is InterfaceFragmentImpl) {
      return self.element;
    } else if (self is LabelFragmentImpl) {
      return self.element2;
    } else if (self is LocalVariableFragmentImpl) {
      return self.element;
    } else if (self is NeverFragmentImpl) {
      return NeverElementImpl.instance;
    } else if (self is ParameterMember) {
      return (self as FormalParameterFragment).element;
    } else if (self is LibraryImportImpl ||
        self is LibraryExportImpl ||
        self is PartIncludeImpl) {
      // There is no equivalent in the new element model.
      return null;
    } else {
      return (self as Fragment?)?.element;
    }
  }
}

extension EnumElementImplExtension on EnumFragmentImpl {
  EnumElementImpl get asElement2 {
    return element;
  }
}

extension ExecutableElement2Extension on ExecutableElement {
  ExecutableElementOrMember get asElement {
    if (this case ExecutableMember member) {
      return member;
    }
    return firstFragment as ExecutableElementOrMember;
  }
}

extension ExecutableElement2OrMemberExtension on ExecutableElement2OrMember {
  ExecutableFragmentImpl get declarationImpl =>
      baseElement.firstFragment as ExecutableFragmentImpl;
}

extension ExecutableElementImpl2Extension on ExecutableElementImpl {
  ExecutableFragmentImpl get asElement {
    return lastFragment;
  }
}

extension ExecutableElementImplExtension on ExecutableFragmentImpl {
  ExecutableElementImpl get asElement2 {
    return element;
  }
}

extension ExecutableElementOrMemberExtension on ExecutableElementOrMember {
  ExecutableElement2OrMember get asElement2 {
    return switch (this) {
      ExecutableFragmentImpl(:var element) => element,
      ExecutableMember member => member,
      _ => throw UnsupportedError('Unsupported type: $runtimeType'),
    };
  }

  ExecutableFragmentImpl get declarationImpl =>
      asElement2.baseElement.firstFragment as ExecutableFragmentImpl;

  FragmentImpl get enclosingElementImpl =>
      asElement2.enclosingElement!.firstFragment as FragmentImpl;
}

extension ExtensionElementImpl2Extension on ExtensionElementImpl {
  ExtensionFragmentImpl get asElement {
    return firstFragment;
  }
}

extension ExtensionElementImplExtension on ExtensionFragmentImpl {
  ExtensionElementImpl get asElement2 {
    return element;
  }
}

extension ExtensionTypeElementImpl2Extension on ExtensionTypeElementImpl {
  ExtensionTypeFragmentImpl get asElement {
    return firstFragment;
  }
}

extension FieldElementImpl2Extension on FieldElementImpl {
  FieldFragmentImpl get asElement {
    return firstFragment;
  }
}

extension FieldElementImplExtension on FieldFragmentImpl {
  FieldElementImpl get asElement2 {
    return element;
  }
}

extension FieldElementOrMemberExtension on FieldElementOrMember {
  FieldElement2OrMember get asElement2 {
    return switch (this) {
      FieldFragmentImpl(:var element) => element,
      FieldMember member => member,
      _ => throw UnsupportedError('Unsupported type: $runtimeType'),
    };
  }
}

extension FormalParameterElementExtension on FormalParameterElement {
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

extension FormalParameterElementImplExtension on FormalParameterElementImpl {
  FormalParameterFragmentImpl get asElement {
    return firstFragment;
  }
}

extension FormalParameterElementMixinExtension on FormalParameterElementMixin {
  ParameterElementMixin get asElement {
    return switch (this) {
      FormalParameterElementImpl(:var firstFragment) => firstFragment,
      ParameterMember member => member,
      _ => throw UnsupportedError('Unsupported type: $runtimeType'),
    };
  }
}

extension GetterElementImplExtension on GetterElementImpl {
  PropertyAccessorFragmentImpl get asElement {
    return lastFragment;
  }
}

extension InstanceElementImpl2Extension on InstanceElementImpl {
  InstanceFragmentImpl get asElement {
    return firstFragment;
  }
}

extension InstanceElementImplExtension on InstanceFragmentImpl {
  InstanceElementImpl get asElement2 {
    return element;
  }
}

extension InterfaceElementImpl2Extension on InterfaceElementImpl {
  InterfaceFragmentImpl get asElement {
    return firstFragment;
  }
}

extension InterfaceElementImplExtension on InterfaceFragmentImpl {
  InterfaceElementImpl get asElement2 {
    return element;
  }
}

extension InterfaceTypeImplExtension on InterfaceTypeImpl {
  InterfaceFragmentImpl get elementImpl => element3.firstFragment;
}

extension JoinPatternVariableElementImplExtension
    on JoinPatternVariableFragmentImpl {
  JoinPatternVariableElementImpl get asElement2 {
    return element;
  }
}

extension LibraryFragmentExtension on LibraryFragment {
  /// Returns a list containing this library fragment and all of its enclosing
  /// fragments.
  List<LibraryFragment> get withEnclosing2 {
    var result = <LibraryFragment>[];
    var current = this;
    while (true) {
      result.add(current);
      if (current.enclosingFragment case var enclosing?) {
        current = enclosing;
      } else {
        break;
      }
    }
    return result;
  }
}

extension ListOfTypeParameterElement2Extension on List<TypeParameterElement> {
  List<TypeParameterType> instantiateNone() {
    return map((e) {
      return e.instantiate(nullabilitySuffix: NullabilitySuffix.none);
    }).toList();
  }
}

extension LocalVariableElementImplExtension on LocalVariableFragmentImpl {
  LocalVariableElementImpl get asElement2 {
    return element;
  }
}

extension MethodElement2OrMemberExtension on MethodElement2OrMember {
  MethodElementOrMember get asElement {
    if (this case MethodMember member) {
      return member;
    }
    return (this as MethodElementImpl).lastFragment;
  }
}

extension MethodElementImpl2Extension on MethodElementImpl {
  MethodFragmentImpl get asElement {
    return lastFragment;
  }
}

extension MethodElementImplExtension on MethodFragmentImpl {
  MethodElementImpl get asElement2 {
    return element;
  }
}

extension MethodElementOrMemberExtension on MethodElementOrMember {
  MethodElement2OrMember get asElement2 {
    return switch (this) {
      MethodFragmentImpl(:var element) => element,
      MethodMember member => member,
      _ => throw UnsupportedError('Unsupported type: $runtimeType'),
    };
  }
}

extension MixinElementImplExtension on MixinFragmentImpl {
  MixinElementImpl get asElement2 {
    return element;
  }
}

extension ParameterElementImplExtension on FormalParameterFragmentImpl {
  FormalParameterElementImpl get asElement2 {
    return element;
  }
}

extension ParameterElementMixinExtension on ParameterElementMixin {
  FormalParameterElementMixin get asElement2 {
    return switch (this) {
      FormalParameterFragmentImpl(:var element) => element,
      ParameterMember member => member,
      _ => throw UnsupportedError('Unsupported type: $runtimeType'),
    };
  }
}

extension PatternVariableElementImpl2Extension on PatternVariableElementImpl {
  PatternVariableFragmentImpl get asElement {
    return firstFragment;
  }
}

extension PatternVariableElementImplExtension on PatternVariableFragmentImpl {
  PatternVariableElementImpl get asElement2 {
    return element;
  }
}

extension PropertyAccessorElement2OrMemberExtension
    on PropertyAccessorElement2OrMember {
  PropertyAccessorElementOrMember get asElement {
    if (this case PropertyAccessorMember member) {
      return member;
    }
    return (this as PropertyAccessorElementImpl).lastFragment;
  }
}

extension PropertyAccessorElementImplExtension on PropertyAccessorFragmentImpl {
  PropertyAccessorElementImpl get asElement2 {
    return element;
  }
}

extension PropertyAccessorElementOrMemberExtension
    on PropertyAccessorElementOrMember {
  PropertyAccessorElement2OrMember get asElement2 {
    return switch (this) {
      PropertyAccessorFragmentImpl(:var element) => element,
      PropertyAccessorMember member => member,
      _ => throw UnsupportedError('Unsupported type: $runtimeType'),
    };
  }
}

extension PropertyInducingElementExtension on PropertyInducingElement {
  bool get definesSetter {
    if (isConst) {
      return false;
    }
    if (isFinal) {
      return isLate && !hasInitializer;
    } else {
      return true;
    }
  }
}

extension PropertyInducingElementOrMemberExtension
    on PropertyInducingElementOrMember {
  PropertyInducingElement2OrMember get asElement2 {
    return switch (this) {
      PropertyInducingFragmentImpl(:var element) => element,
      FieldMember member => member,
      _ => throw UnsupportedError('Unsupported type: $runtimeType'),
    };
  }
}

extension SetterElementImplExtension on SetterElementImpl {
  PropertyAccessorFragmentImpl get asElement {
    return lastFragment;
  }
}

extension TopLevelFunctionElementImplExtension on TopLevelFunctionElementImpl {
  FunctionFragmentImpl get asElement {
    return lastFragment;
  }
}

extension TopLevelVariableElementImpl2Extension on TopLevelVariableElementImpl {
  TopLevelVariableFragmentImpl get asElement {
    return firstFragment;
  }
}

extension TypeAliasElementImpl2Extension on TypeAliasElementImpl {
  TypeAliasFragmentImpl get asElement {
    return firstFragment;
  }
}

extension TypeAliasElementImplExtension on TypeAliasFragmentImpl {
  TypeAliasElementImpl get asElement2 {
    return element;
  }
}

extension TypeParameterElement2Extension on TypeParameterElement {
  TypeParameterElementImpl freshCopy() {
    var fragment = TypeParameterFragmentImpl(name2: name3, nameOffset: -1);
    fragment.bound = bound;
    return TypeParameterElementImpl(firstFragment: fragment, name3: name3);
  }
}

extension TypeParameterElementImpl2Extension on TypeParameterElementImpl {
  TypeParameterFragmentImpl get asElement {
    return firstFragment;
  }
}

extension TypeParameterElementImplExtension on TypeParameterFragmentImpl {
  TypeParameterElementImpl get asElement2 {
    return element;
  }
}
