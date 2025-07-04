// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:_fe_analyzer_shared/src/type_inference/type_analyzer_operations.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/source/source.dart';
import 'package:analyzer/source/source_range.dart';
import 'package:analyzer/src/dart/analysis/experiments.dart';
import 'package:analyzer/src/dart/analysis/info_declaration_store.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/field_name_non_promotability_info.dart';
import 'package:analyzer/src/dart/element/member.dart';
import 'package:analyzer/src/dart/element/name_union.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/element/type_algebra.dart';
import 'package:analyzer/src/error/inference_error.dart';
import 'package:analyzer/src/fine/library_manifest.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:analyzer/src/summary2/ast_binary_reader.dart';
import 'package:analyzer/src/summary2/ast_binary_tag.dart';
import 'package:analyzer/src/summary2/data_reader.dart';
import 'package:analyzer/src/summary2/element_flags.dart';
import 'package:analyzer/src/summary2/export.dart';
import 'package:analyzer/src/summary2/informative_data.dart';
import 'package:analyzer/src/summary2/linked_element_factory.dart';
import 'package:analyzer/src/summary2/reference.dart';
import 'package:analyzer/src/utilities/extensions/element.dart';
import 'package:analyzer/src/utilities/uri_cache.dart';
import 'package:pub_semver/pub_semver.dart';

class BundleReader {
  final SummaryDataReader _reader;
  final Map<Uri, Uint8List> _unitsInformativeBytes;
  final InfoDeclarationStore _infoDeclarationStore;

  final Map<Uri, LibraryReader> libraryMap = {};

  BundleReader({
    required LinkedElementFactory elementFactory,
    required Uint8List resolutionBytes,
    Map<Uri, Uint8List> unitsInformativeBytes = const {},
    required InfoDeclarationStore infoDeclarationStore,
    required Map<Uri, LibraryManifest> libraryManifests,
  }) : _reader = SummaryDataReader(resolutionBytes),
       _unitsInformativeBytes = unitsInformativeBytes,
       _infoDeclarationStore = infoDeclarationStore {
    const bytesOfU32 = 4;
    const countOfU32 = 4;
    _reader.offset = _reader.bytes.length - bytesOfU32 * countOfU32;
    var baseResolutionOffset = _reader.readUInt32();
    var librariesOffset = _reader.readUInt32();
    var referencesOffset = _reader.readUInt32();
    var stringsOffset = _reader.readUInt32();
    _reader.createStringTable(stringsOffset);

    var referenceReader = _ReferenceReader(
      elementFactory,
      _reader,
      referencesOffset,
    );

    _reader.offset = librariesOffset;
    var libraryHeaderList = _reader.readTypedList(() {
      return _LibraryHeader(
        uri: uriCache.parse(_reader.readStringReference()),
        offset: _reader.readUInt30(),
      );
    });

    for (var libraryHeader in libraryHeaderList) {
      var uri = libraryHeader.uri;
      var reference = elementFactory.rootReference.getChild('$uri');
      libraryMap[uri] = LibraryReader._(
        elementFactory: elementFactory,
        reader: _reader,
        uri: uri,
        unitsInformativeBytes: _unitsInformativeBytes,
        baseResolutionOffset: baseResolutionOffset,
        referenceReader: referenceReader,
        reference: reference,
        offset: libraryHeader.offset,
        infoDeclarationStore: _infoDeclarationStore,
        manifest: libraryManifests[uri],
      );
    }
  }
}

class LibraryReader {
  final LinkedElementFactory _elementFactory;
  final SummaryDataReader _reader;
  final Uri uri;
  final Map<Uri, Uint8List> _unitsInformativeBytes;
  final int _baseResolutionOffset;
  final _ReferenceReader _referenceReader;
  final Reference _reference;
  final int _offset;
  final InfoDeclarationStore _deserializedDataStore;
  final LibraryManifest? manifest;

  late final LibraryElementImpl _libraryElement;

  /// Map of unique (in the bundle) IDs to fragments.
  final Map<int, FragmentImpl> idFragmentMap = {};

  LibraryReader._({
    required LinkedElementFactory elementFactory,
    required SummaryDataReader reader,
    required this.uri,
    required Map<Uri, Uint8List> unitsInformativeBytes,
    required int baseResolutionOffset,
    required _ReferenceReader referenceReader,
    required Reference reference,
    required int offset,
    required InfoDeclarationStore infoDeclarationStore,
    required this.manifest,
  }) : _elementFactory = elementFactory,
       _reader = reader,
       _unitsInformativeBytes = unitsInformativeBytes,
       _baseResolutionOffset = baseResolutionOffset,
       _referenceReader = referenceReader,
       _reference = reference,
       _offset = offset,
       _deserializedDataStore = infoDeclarationStore;

  LibraryElementImpl readElement({required Source librarySource}) {
    var analysisContext = _elementFactory.analysisContext;
    var analysisSession = _elementFactory.analysisSession;

    _reader.offset = _offset;

    // Read enough data to create the library.
    var name = _reader.readStringReference();
    var featureSet = _readFeatureSet();

    // Create the library, link to the reference.
    _libraryElement = LibraryElementImpl(
      analysisContext,
      analysisSession,
      name,
      -1,
      0,
      featureSet,
    );
    _reference.element = _libraryElement;
    _libraryElement.reference = _reference;

    // Read the rest of non-resolution data for the library.
    LibraryElementFlags.read(_reader, _libraryElement);
    _libraryElement.languageVersion = _readLanguageVersion();

    _libraryElement.exportedReferences = _reader.readTypedList(
      _readExportedReference,
    );

    _libraryElement.nameUnion = ElementNameUnion.read(_reader.readUInt30List());

    _libraryElement.manifest = manifest;

    _libraryElement.loadLibraryProvider = LoadLibraryFunctionProvider(
      elementReference: _readReference(),
    );

    // Read the library units.
    _libraryElement.definingCompilationUnit = _readUnitElement(
      containerUnit: null,
      unitSource: librarySource,
    );

    _readClassElements();
    _readEnumElements();
    _readExtensionElements();
    _readExtensionTypeElements();
    _readTopLevelFunctionElements();
    _readMixinElements();
    _readTypeAliasElements();
    _readTopLevelVariableElements();
    _libraryElement.getters = _readGetterElements();
    _libraryElement.setters = _readSetterElements();
    _readVariableGetterSetterLinking();

    var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();
    _libraryElement.deferReadResolution(() {
      var unitElement = _libraryElement.definingCompilationUnit;
      var reader = ResolutionReader(
        _elementFactory,
        _referenceReader,
        _reader.fork(resolutionOffset),
      );
      reader.currentLibraryFragment = unitElement;

      _libraryElement.metadata = reader._readMetadata(unitElement: unitElement);

      _libraryElement.entryPoint2 =
          reader.readElement() as TopLevelFunctionElementImpl?;

      _libraryElement.fieldNameNonPromotabilityInfo = reader.readOptionalObject(
        () {
          return reader.readMap(
            readKey: () => reader.readStringReference(),
            readValue: () {
              return FieldNameNonPromotabilityInfo(
                conflictingFields: reader.readElementList(),
                conflictingGetters: reader.readElementList(),
                conflictingNsmClasses: reader.readElementList(),
              );
            },
          );
        },
      );

      _libraryElement.exportNamespace = _elementFactory.buildExportNamespace(
        _libraryElement.source.uri,
        _libraryElement.exportedReferences,
      );
    });

    _declareDartCoreDynamicNever();

    InformativeDataApplier(
      _elementFactory,
      _unitsInformativeBytes,
      _deserializedDataStore,
    ).applyTo(_libraryElement);

    return _libraryElement;
  }

  void Function() _createDeferredReadResolutionCallback(
    void Function(ResolutionReader reader) callback,
  ) {
    var offset = _baseResolutionOffset + _reader.readUInt30();
    return () {
      var reader = ResolutionReader(
        _elementFactory,
        _referenceReader,
        _reader.fork(offset),
      );
      callback(reader);
    };
  }

  /// These elements are implicitly declared in `dart:core`.
  void _declareDartCoreDynamicNever() {
    if (_reference.name == 'dart:core') {
      _reference.getChild('dynamic').element = DynamicElementImpl.instance;
      _reference.getChild('Never').element = NeverElementImpl.instance;
    }
  }

  /// Configures to read lazy data with [operation].
  ///
  /// Expected state of the reader:
  ///   - length of data to read lazily
  ///   - data to read lazily
  ///   - data to continue reading eagerly
  void _lazyRead(void Function(int offset) operation) {
    var length = _reader.readUInt30();
    var offset = _reader.offset;
    _reader.offset += length;
    operation(offset);
  }

  void _readClassElements() {
    _libraryElement.classes = _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<ClassFragmentImpl>();
      // TODO(scheglov): link fragments.
      var element = ClassElementImpl(reference, fragments.first);

      // Configure for reading members lazily.
      _lazyRead((offset) {
        element.deferReadMembers(() {
          _reader.runAtOffset(offset, () {
            for (var fragment in element.fragments) {
              fragment.ensureReadMembers();
            }

            element.fields = _readFieldElements();
            element.getters = _readGetterElements();
            element.setters = _readSetterElements();
            _readVariableGetterSetterLinking();
            element.methods = _readMethodElements();
            if (!element.isMixinApplication) {
              element.constructors = _readConstructorElements();
            }
          });
        });
      });

      element.deferReadResolution(
        _createDeferredReadResolutionCallback((reader) {
          // TODO(scheglov): read resolution information
        }),
      );

      return element;
    });
  }

  void _readClassFragments(LibraryFragmentImpl libraryFragment) {
    libraryFragment.classes = _reader.readTypedList(() {
      return _readTemplateFragment(
        create: (name) {
          var fragment = ClassFragmentImpl(name2: name, nameOffset: -1);
          ClassElementFlags.read(_reader, fragment);
          fragment.typeParameters = _readTypeParameters();

          _lazyRead((membersOffset) {
            fragment.deferReadMembers(() {
              _reader.runAtOffset(membersOffset, () {
                _readFieldFragments(fragment);
                fragment.getters = _readGetterFragments();
                fragment.setters = _readSetterFragments();
                _readMethodFragments(fragment);
                if (!fragment.isMixinApplication) {
                  _readConstructorFragments(fragment);
                }

                // TODO(scheglov): this is ugly
                if (fragment.applyMembersConstantOffsets case var callback?) {
                  fragment.applyMembersConstantOffsets = null;
                  callback();
                }
              });
            });
          });
          return fragment;
        },
        readResolution: (fragment, reader) {
          _readTypeParameters2(
            fragment.libraryFragment,
            reader,
            fragment.typeParameters,
          );
          _readFragmentMetadata(fragment, reader);
          fragment.supertype = reader._readOptionalInterfaceType();
          fragment.mixins = reader._readInterfaceTypeList();
          fragment.interfaces = reader._readInterfaceTypeList();
        },
      );
    });
  }

  List<ConstructorElementImpl> _readConstructorElements() {
    return _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<ConstructorFragmentImpl>();
      // TODO(scheglov): link fragments.
      return ConstructorElementImpl(
        name3: fragments.first.name2,
        reference: reference,
        firstFragment: fragments.first,
      );
    });
  }

  void _readConstructorFragments(InterfaceFragmentImpl interfaceFragment) {
    interfaceFragment.constructors = _reader.readTypedList(() {
      var id = _readFragmentId();
      var name = _readFragmentName()!;
      var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();
      var fragment = ConstructorFragmentImpl(name2: name, nameOffset: -1);
      idFragmentMap[id] = fragment;

      fragment.readModifiers(_reader);
      fragment.typeName = _reader.readOptionalStringReference();
      fragment.typeParameters = _readTypeParameters();
      fragment.parameters = _readParameters();

      fragment.deferReadResolution(() {
        var reader = ResolutionReader(
          _elementFactory,
          _referenceReader,
          _reader.fork(resolutionOffset),
        );

        var eee = fragment.element.enclosingElement as InstanceElementImpl;
        reader._addTypeParameters2(eee.typeParameters2);

        _readTypeParameters2(
          fragment.libraryFragment,
          reader,
          fragment.typeParameters,
        );
        _readFormalParameters2(
          fragment.libraryFragment,
          reader,
          fragment.parameters,
        );
        _readFragmentMetadata(fragment, reader);
        fragment.returnType = reader.readRequiredType();
        fragment.superConstructor = reader.readConstructorElementMixin();
        fragment.redirectedConstructor = reader.readConstructorElementMixin();
        fragment.constantInitializers = reader.readNodeList();
      });

      return fragment;
    });
  }

  DirectiveUriImpl _readDirectiveUri({
    required LibraryFragmentImpl containerUnit,
  }) {
    DirectiveUriWithRelativeUriStringImpl readWithRelativeUriString() {
      var relativeUriString = _reader.readStringReference();
      return DirectiveUriWithRelativeUriStringImpl(
        relativeUriString: relativeUriString,
      );
    }

    DirectiveUriWithRelativeUriImpl readWithRelativeUri() {
      var parent = readWithRelativeUriString();
      var relativeUri = uriCache.parse(_reader.readStringReference());
      return DirectiveUriWithRelativeUriImpl(
        relativeUriString: parent.relativeUriString,
        relativeUri: relativeUri,
      );
    }

    DirectiveUriWithSourceImpl readWithSource() {
      var parent = readWithRelativeUri();

      var analysisContext = _elementFactory.analysisContext;
      var sourceFactory = analysisContext.sourceFactory;

      var sourceUriStr = _reader.readStringReference();
      var sourceUri = uriCache.parse(sourceUriStr);
      var source = sourceFactory.forUri2(sourceUri);

      // TODO(scheglov): https://github.com/dart-lang/sdk/issues/49431
      var fixedSource = source ?? sourceFactory.forUri('dart:math')!;

      return DirectiveUriWithSourceImpl(
        relativeUriString: parent.relativeUriString,
        relativeUri: parent.relativeUri,
        source: fixedSource,
      );
    }

    var kindIndex = _reader.readByte();
    var kind = DirectiveUriKind.values[kindIndex];
    switch (kind) {
      case DirectiveUriKind.withLibrary:
        var parent = readWithSource();
        return DirectiveUriWithLibraryImpl.read(
          relativeUriString: parent.relativeUriString,
          relativeUri: parent.relativeUri,
          source: parent.source,
        );
      case DirectiveUriKind.withUnit:
        var parent = readWithSource();
        var unitElement = _readUnitElement(
          containerUnit: containerUnit,
          unitSource: parent.source,
        );
        return DirectiveUriWithUnitImpl(
          relativeUriString: parent.relativeUriString,
          relativeUri: parent.relativeUri,
          libraryFragment: unitElement,
        );
      case DirectiveUriKind.withSource:
        return readWithSource();
      case DirectiveUriKind.withRelativeUri:
        return readWithRelativeUri();
      case DirectiveUriKind.withRelativeUriString:
        return readWithRelativeUriString();
      case DirectiveUriKind.withNothing:
        return DirectiveUriImpl();
    }
  }

  void _readEnumElements() {
    _libraryElement.enums = _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<EnumFragmentImpl>();
      // TODO(scheglov): link fragments.
      var element = EnumElementImpl(reference, fragments.first);

      // TODO(scheglov): consider reading lazily
      for (var fragment in element.fragments) {
        fragment.ensureReadMembers();
      }

      element.fields = _readFieldElements();
      element.getters = _readGetterElements();
      element.setters = _readSetterElements();
      _readVariableGetterSetterLinking();
      element.constructors = _readConstructorElements();
      element.methods = _readMethodElements();

      element.deferReadResolution(
        _createDeferredReadResolutionCallback((reader) {
          // TODO(scheglov): read resolution information
        }),
      );

      return element;
    });
  }

  void _readEnumFragments(LibraryFragmentImpl libraryFragment) {
    libraryFragment.enums = _reader.readTypedList(() {
      return _readTemplateFragment(
        create: (name) {
          var fragment = EnumFragmentImpl(name2: name, nameOffset: -1);
          EnumElementFlags.read(_reader, fragment);
          fragment.typeParameters = _readTypeParameters();

          // TODO(scheglov): consider reading lazily
          _readFieldFragments(fragment);
          fragment.getters = _readGetterFragments();
          fragment.setters = _readSetterFragments();
          _readConstructorFragments(fragment);
          _readMethodFragments(fragment);
          return fragment;
        },
        readResolution: (fragment, reader) {
          _readTypeParameters2(
            fragment.libraryFragment,
            reader,
            fragment.typeParameters,
          );
          _readFragmentMetadata(fragment, reader);
          fragment.supertype = reader._readOptionalInterfaceType();
          fragment.mixins = reader._readInterfaceTypeList();
          fragment.interfaces = reader._readInterfaceTypeList();
        },
      );
    });
  }

  ExportedReference _readExportedReference() {
    var kind = _reader.readByte();
    if (kind == 0) {
      var index = _reader.readUInt30();
      var reference = _referenceReader.referenceOfIndex(index);
      return ExportedReferenceDeclared(reference: reference);
    } else if (kind == 1) {
      var index = _reader.readUInt30();
      var reference = _referenceReader.referenceOfIndex(index);
      return ExportedReferenceExported(
        reference: reference,
        locations: _reader.readTypedList(_readExportLocation),
      );
    } else {
      throw StateError('kind: $kind');
    }
  }

  ExportLocation _readExportLocation() {
    return ExportLocation(
      fragmentIndex: _reader.readUInt30(),
      exportIndex: _reader.readUInt30(),
    );
  }

  void _readExtensionElements() {
    _libraryElement.extensions = _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<ExtensionFragmentImpl>();
      // TODO(scheglov): link fragments.
      var element = ExtensionElementImpl(reference, fragments.first);

      for (var fragment in element.fragments) {
        fragment.ensureReadMembers();
      }

      // TODO(scheglov): consider reading lazily
      element.fields = _readFieldElements();
      element.getters = _readGetterElements();
      element.setters = _readSetterElements();
      _readVariableGetterSetterLinking();
      element.methods = _readMethodElements();

      element.deferReadResolution(
        _createDeferredReadResolutionCallback((reader) {
          reader._addTypeParameters2(element.typeParameters2);
          element.extendedType = reader.readRequiredType();
          // TODO(scheglov): read resolution information
        }),
      );

      return element;
    });
  }

  void _readExtensionFragments(LibraryFragmentImpl libraryFragment) {
    libraryFragment.extensions = _reader.readTypedList(() {
      return _readTemplateFragment(
        create: (name) {
          var fragment = ExtensionFragmentImpl(name2: name, nameOffset: -1);
          ExtensionElementFlags.read(_reader, fragment);
          fragment.typeParameters = _readTypeParameters();
          _readFieldFragments(fragment);
          fragment.getters = _readGetterFragments();
          fragment.setters = _readSetterFragments();
          _readMethodFragments(fragment);
          return fragment;
        },
        readResolution: (fragment, reader) {
          _readTypeParameters2(
            fragment.libraryFragment,
            reader,
            fragment.typeParameters,
          );
          _readFragmentMetadata(fragment, reader);
        },
      );
    });
  }

  void _readExtensionTypeElements() {
    _libraryElement.extensionTypes = _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<ExtensionTypeFragmentImpl>();
      // TODO(scheglov): link fragments.
      var element = ExtensionTypeElementImpl(reference, fragments.first);

      // TODO(scheglov): consider reading lazily
      for (var fragment in element.fragments) {
        fragment.ensureReadMembers();
      }

      element.fields = _readFieldElements();
      element.getters = _readGetterElements();
      element.setters = _readSetterElements();
      _readVariableGetterSetterLinking();
      element.constructors = _readConstructorElements();
      element.methods = _readMethodElements();

      element.deferReadResolution(
        _createDeferredReadResolutionCallback((reader) {
          // TODO(scheglov): read resolution information
        }),
      );

      return element;
    });
  }

  void _readExtensionTypeFragments(LibraryFragmentImpl libraryFragment) {
    libraryFragment.extensionTypes = _reader.readTypedList(() {
      return _readTemplateFragment(
        create: (name) {
          var fragment = ExtensionTypeFragmentImpl(name2: name, nameOffset: -1);
          ExtensionTypeElementFlags.read(_reader, fragment);
          fragment.typeParameters = _readTypeParameters();

          // TODO(scheglov): consider reading lazily
          _readFieldFragments(fragment);
          fragment.getters = _readGetterFragments();
          fragment.setters = _readSetterFragments();
          _readConstructorFragments(fragment);
          _readMethodFragments(fragment);
          return fragment;
        },
        readResolution: (fragment, reader) {
          _readTypeParameters2(
            fragment.libraryFragment,
            reader,
            fragment.typeParameters,
          );
          _readFragmentMetadata(fragment, reader);
          fragment.interfaces = reader._readInterfaceTypeList();
          fragment.typeErasure = reader.readRequiredType();
        },
      );
    });
  }

  FeatureSet _readFeatureSet() {
    var featureSetEncoded = _reader.readUint8List();
    return ExperimentStatus.fromStorage(featureSetEncoded);
  }

  List<FieldElementImpl> _readFieldElements() {
    return _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<FieldFragmentImpl>();
      // TODO(scheglov): link fragments.
      return FieldElementImpl(
        reference: reference,
        firstFragment: fragments.first,
      );
    });
  }

  void _readFieldFragments(InstanceFragmentImpl instanceFragment) {
    instanceFragment.fields = _reader.readTypedList(() {
      var id = _readFragmentId();
      var name = _readFragmentName();
      var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();
      var fragment = FieldFragmentImpl(name2: name, nameOffset: -1);
      idFragmentMap[id] = fragment;

      fragment.readModifiers(_reader);

      fragment.deferReadResolution(() {
        var reader = ResolutionReader(
          _elementFactory,
          _referenceReader,
          _reader.fork(resolutionOffset),
        );

        var enclosingElement =
            fragment.element.enclosingElement as InstanceElementImpl;
        reader._addTypeParameters2(enclosingElement.typeParameters2);

        _readFragmentMetadata(fragment, reader);
        fragment.type = reader.readRequiredType();
        if (reader.readOptionalExpression() case var initializer?) {
          fragment.constantInitializer = initializer;
          ConstantContextForExpressionImpl(fragment, initializer);
        }
      });

      return fragment;
    });
  }

  void _readFormalParameters2(
    LibraryFragmentImpl unitElement,
    ResolutionReader reader,
    List<FormalParameterFragmentImpl> parameters,
  ) {
    for (var parameter in parameters) {
      parameter.metadata = reader._readMetadata(unitElement: unitElement);
      _readTypeParameters2(unitElement, reader, parameter.typeParameters);
      _readFormalParameters2(unitElement, reader, parameter.parameters);
      parameter.type = reader.readRequiredType();
      if (parameter is ConstVariableFragment) {
        var defaultParameter = parameter as ConstVariableFragment;
        var initializer = reader.readOptionalExpression();
        if (initializer != null) {
          defaultParameter.constantInitializer = initializer;
        }
      }
      if (parameter is FieldFormalParameterFragmentImpl) {
        // TODO(scheglov): use element
        parameter.field =
            (reader.readElement() as FieldElementImpl?)?.firstFragment;
        // parameter.field = reader.readFragmentOrMember() as FieldFragmentImpl?;
      }
    }
  }

  T _readFragmentById<T extends FragmentImpl>() {
    var id = _readFragmentId();
    return idFragmentMap[id] as T;
  }

  int _readFragmentId() {
    return _reader.readUInt30();
  }

  void _readFragmentMetadata<T extends AnnotatableFragmentImpl>(
    T fragment,
    ResolutionReader reader,
  ) {
    var libraryFragment = fragment.libraryFragment as LibraryFragmentImpl;
    fragment.metadata = reader._readMetadata(unitElement: libraryFragment);
  }

  String? _readFragmentName() {
    return _reader.readOptionalStringReference();
  }

  List<T> _readFragmentsById<T extends FragmentImpl>() {
    return _reader.readTypedList(_readFragmentById);
  }

  List<GetterElementImpl> _readGetterElements() {
    return _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<GetterFragmentImpl>();
      // TODO(scheglov): link fragments.
      var element = GetterElementImpl(reference, fragments.first);

      element.deferReadResolution(
        _createDeferredReadResolutionCallback((reader) {
          // TODO(scheglov): review
          var eee = element.enclosingElement;
          if (eee is InstanceElementImpl) {
            reader._addTypeParameters2(eee.typeParameters2);
          }

          element.returnType = reader.readRequiredType();
        }),
      );

      return element;
    });
  }

  List<GetterFragmentImpl> _readGetterFragments() {
    return _reader.readTypedList(() {
      var id = _readFragmentId();
      var name = _readFragmentName();
      var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();
      var fragment = GetterFragmentImpl(name2: name, nameOffset: -1);
      idFragmentMap[id] = fragment;

      fragment.readModifiers(_reader);
      fragment.typeParameters = _readTypeParameters();
      fragment.parameters = _readParameters();

      fragment.deferReadResolution(() {
        var reader = ResolutionReader(
          _elementFactory,
          _referenceReader,
          _reader.fork(resolutionOffset),
        );

        // TODO(scheglov): review
        var eee = fragment.element.enclosingElement;
        if (eee is InstanceElementImpl) {
          reader._addTypeParameters2(eee.typeParameters2);
        }

        _readTypeParameters2(
          fragment.libraryFragment,
          reader,
          fragment.typeParameters,
        );
        _readFormalParameters2(
          fragment.libraryFragment,
          reader,
          fragment.parameters,
        );
        _readFragmentMetadata(fragment, reader);
        fragment.returnType = reader.readRequiredType();
      });

      return fragment;
    });
  }

  LibraryLanguageVersion _readLanguageVersion() {
    var packageMajor = _reader.readUInt30();
    var packageMinor = _reader.readUInt30();
    var package = Version(packageMajor, packageMinor, 0);

    Version? override;
    if (_reader.readBool()) {
      var overrideMajor = _reader.readUInt30();
      var overrideMinor = _reader.readUInt30();
      override = Version(overrideMajor, overrideMinor, 0);
    }

    return LibraryLanguageVersion(package: package, override: override);
  }

  LibraryExportImpl _readLibraryExport({
    required LibraryFragmentImpl containerUnit,
  }) {
    return LibraryExportImpl(
      combinators: _reader.readTypedList(_readNamespaceCombinator),
      exportKeywordOffset: -1,
      uri: _readDirectiveUri(containerUnit: containerUnit),
    );
  }

  LibraryImportImpl _readLibraryImport({
    required LibraryFragmentImpl containerUnit,
  }) {
    var element = LibraryImportImpl(
      isSynthetic: _reader.readBool(),
      combinators: _reader.readTypedList(_readNamespaceCombinator),
      importKeywordOffset: -1,
      prefix2: _readLibraryImportPrefixFragment(libraryFragment: containerUnit),
      uri: _readDirectiveUri(containerUnit: containerUnit),
    );
    return element;
  }

  PrefixFragmentImpl? _readLibraryImportPrefixFragment({
    required LibraryFragmentImpl libraryFragment,
  }) {
    return _reader.readOptionalObject(() {
      var fragmentName = _readFragmentName();
      var reference = _readReference();
      var isDeferred = _reader.readBool();
      var fragment = PrefixFragmentImpl(
        enclosingFragment: libraryFragment,
        name2: fragmentName,
        nameOffset2: null,
        isDeferred: isDeferred,
      );

      var element = reference.element as PrefixElementImpl?;
      if (element == null) {
        element = PrefixElementImpl(
          reference: reference,
          firstFragment: fragment,
        );
      } else {
        element.addFragment(fragment);
      }

      fragment.element = element;
      return fragment;
    });
  }

  List<MethodElementImpl> _readMethodElements() {
    return _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<MethodFragmentImpl>();
      // TODO(scheglov): link fragments.
      var element = MethodElementImpl(
        name3: fragments.first.name2,
        reference: reference,
        firstFragment: fragments.first,
      );

      // TODO(scheglov): type parameters
      // TODO(scheglov): formal parameters
      element.deferReadResolution(
        _createDeferredReadResolutionCallback((reader) {
          var enclosingElement =
              element.enclosingElement as InstanceElementImpl;
          reader._addTypeParameters2(enclosingElement.typeParameters2);

          // TODO(scheglov): remove cast
          reader._addTypeParameters2(element.typeParameters2.cast());

          element.returnType = reader.readRequiredType();
        }),
      );

      return element;
    });
  }

  void _readMethodFragments(InstanceFragmentImpl instanceFragment) {
    instanceFragment.methods = _reader.readTypedList(() {
      var id = _readFragmentId();
      var name = _readFragmentName();
      var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();
      var fragment = MethodFragmentImpl(name2: name, nameOffset: -1);
      idFragmentMap[id] = fragment;

      fragment.readModifiers(_reader);
      fragment.typeInferenceError = _readTopLevelInferenceError();
      fragment.typeParameters = _readTypeParameters();
      fragment.parameters = _readParameters();

      fragment.deferReadResolution(() {
        var reader = ResolutionReader(
          _elementFactory,
          _referenceReader,
          _reader.fork(resolutionOffset),
        );

        var enclosingElement =
            fragment.element.enclosingElement as InstanceElementImpl;
        reader._addTypeParameters2(enclosingElement.typeParameters2);

        _readTypeParameters2(
          fragment.libraryFragment,
          reader,
          fragment.typeParameters,
        );
        _readFormalParameters2(
          fragment.libraryFragment,
          reader,
          fragment.parameters,
        );
        _readFragmentMetadata(fragment, reader);
        fragment.returnType = reader.readRequiredType();
      });

      return fragment;
    });
  }

  void _readMixinElements() {
    _libraryElement.mixins = _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<MixinFragmentImpl>();
      // TODO(scheglov): link fragments.
      var element = MixinElementImpl(reference, fragments.first);

      // TODO(scheglov): consider reading lazily
      for (var fragment in element.fragments) {
        fragment.ensureReadMembers();
      }

      element.fields = _readFieldElements();
      element.getters = _readGetterElements();
      element.setters = _readSetterElements();
      _readVariableGetterSetterLinking();
      element.constructors = _readConstructorElements();
      element.methods = _readMethodElements();

      element.deferReadResolution(
        _createDeferredReadResolutionCallback((reader) {
          // TODO(scheglov): read resolution information
        }),
      );

      return element;
    });
  }

  void _readMixinFragments(LibraryFragmentImpl libraryFragment) {
    libraryFragment.mixins = _reader.readTypedList(() {
      return _readTemplateFragment(
        create: (name) {
          var fragment = MixinFragmentImpl(name2: name, nameOffset: -1);
          MixinElementFlags.read(_reader, fragment);
          fragment.superInvokedNames = _reader.readStringReferenceList();
          fragment.typeParameters = _readTypeParameters();

          // TODO(scheglov): consider reading lazily
          _readFieldFragments(fragment);
          fragment.getters = _readGetterFragments();
          fragment.setters = _readSetterFragments();
          _readConstructorFragments(fragment);
          _readMethodFragments(fragment);
          return fragment;
        },
        readResolution: (fragment, reader) {
          _readTypeParameters2(
            fragment.libraryFragment,
            reader,
            fragment.typeParameters,
          );
          _readFragmentMetadata(fragment, reader);
          // _readTypeParameters(reader, fragment.typeParameters);
          fragment.superclassConstraints = reader._readInterfaceTypeList();
          fragment.interfaces = reader._readInterfaceTypeList();
        },
      );
    });
  }

  NamespaceCombinator _readNamespaceCombinator() {
    var tag = _reader.readByte();
    if (tag == Tag.HideCombinator) {
      var combinator = HideElementCombinatorImpl();
      combinator.hiddenNames = _reader.readStringReferenceList();
      return combinator;
    } else if (tag == Tag.ShowCombinator) {
      var combinator = ShowElementCombinatorImpl();
      combinator.shownNames = _reader.readStringReferenceList();
      return combinator;
    } else {
      throw UnimplementedError('tag: $tag');
    }
  }

  /// Read the reference of a non-local element.
  Reference? _readOptionalReference() {
    return _reader.readOptionalObject(() => _readReference());
  }

  // TODO(scheglov): Deduplicate parameter reading implementation.
  List<FormalParameterFragmentImpl> _readParameters() {
    return _reader.readTypedList(() {
      var id = _readFragmentId();
      var fragmentName = _readFragmentName();
      var isDefault = _reader.readBool();
      var isInitializingFormal = _reader.readBool();
      var isSuperFormal = _reader.readBool();

      var kindIndex = _reader.readByte();
      var kind = ResolutionReader._formalParameterKind(kindIndex);

      FormalParameterFragmentImpl element;
      if (!isDefault) {
        if (isInitializingFormal) {
          element = FieldFormalParameterFragmentImpl(
            nameOffset: -1,
            name2: fragmentName,
            nameOffset2: null,
            parameterKind: kind,
          );
        } else if (isSuperFormal) {
          element = SuperFormalParameterFragmentImpl(
            nameOffset: -1,
            name2: fragmentName,
            nameOffset2: null,
            parameterKind: kind,
          );
        } else {
          element = FormalParameterFragmentImpl(
            nameOffset: -1,
            name2: fragmentName,
            nameOffset2: null,
            parameterKind: kind,
          );
        }
      } else {
        if (isInitializingFormal) {
          element = DefaultFieldFormalParameterElementImpl(
            nameOffset: -1,
            name2: fragmentName,
            nameOffset2: null,
            parameterKind: kind,
          );
        } else if (isSuperFormal) {
          element = DefaultSuperFormalParameterElementImpl(
            nameOffset: -1,
            name2: fragmentName,
            nameOffset2: null,
            parameterKind: kind,
          );
        } else {
          element = DefaultParameterFragmentImpl(
            nameOffset: -1,
            name2: fragmentName,
            nameOffset2: null,
            parameterKind: kind,
          );
        }
      }
      idFragmentMap[id] = element;
      ParameterElementFlags.read(_reader, element);
      element.typeParameters = _readTypeParameters();
      element.parameters = _readParameters();
      return element;
    });
  }

  PartIncludeImpl _readPartInclude({
    required LibraryFragmentImpl containerUnit,
  }) {
    var uri = _readDirectiveUri(containerUnit: containerUnit);

    return PartIncludeImpl(uri: uri);
  }

  /// Read the reference of a non-local element.
  Reference _readReference() {
    var referenceIndex = _reader.readUInt30();
    return _referenceReader.referenceOfIndex(referenceIndex);
  }

  List<SetterElementImpl> _readSetterElements() {
    return _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<SetterFragmentImpl>();
      // TODO(scheglov): link fragments.
      var element = SetterElementImpl(reference, fragments.first);

      element.deferReadResolution(
        _createDeferredReadResolutionCallback((reader) {
          // TODO(scheglov): add to element
          var valueFragment = fragments.first.valueFormalParameter;
          if (valueFragment != null) {
            // TODO(scheglov): create, not get
            valueFragment.element;
          }

          element.returnType = reader.readRequiredType();
          // TODO(scheglov): other properties?
        }),
      );

      return element;
    });
  }

  List<SetterFragmentImpl> _readSetterFragments() {
    return _reader.readTypedList(() {
      var id = _readFragmentId();
      var name = _readFragmentName();
      var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();
      var fragment = SetterFragmentImpl(name2: name, nameOffset: -1);
      idFragmentMap[id] = fragment;

      fragment.readModifiers(_reader);
      fragment.typeParameters = _readTypeParameters();
      fragment.parameters = _readParameters();

      fragment.deferReadResolution(() {
        var reader = ResolutionReader(
          _elementFactory,
          _referenceReader,
          _reader.fork(resolutionOffset),
        );

        var enclosingElement = fragment.element.enclosingElement;
        if (enclosingElement is InstanceElementImpl) {
          reader._addTypeParameters2(enclosingElement.typeParameters2);
        }

        _readTypeParameters2(
          fragment.libraryFragment,
          reader,
          fragment.typeParameters,
        );
        _readFormalParameters2(
          fragment.libraryFragment,
          reader,
          fragment.parameters,
        );
        _readFragmentMetadata(fragment, reader);
        fragment.returnType = reader.readRequiredType();
      });

      return fragment;
    });
  }

  /// [T] must also implement [DeferredResolutionReadingMixin], we configure
  /// it with [readResolution].
  T _readTemplateFragment<T extends FragmentImpl>({
    required T Function(String? name) create,
    required void Function(T fragment, ResolutionReader reader) readResolution,
  }) {
    var id = _readFragmentId();
    var name = _readFragmentName();
    var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();
    var fragment = create(name);
    idFragmentMap[id] = fragment;

    if (fragment case DeferredResolutionReadingMixin deferred) {
      deferred.deferReadResolution(() {
        var reader = ResolutionReader(
          _elementFactory,
          _referenceReader,
          _reader.fork(resolutionOffset),
        );

        // TODO(scheglov): type casts are not good :-(
        reader.currentLibraryFragment =
            fragment.libraryFragment as LibraryFragmentImpl;

        readResolution(fragment, reader);
      });
    }

    return fragment;
  }

  void _readTopLevelFunctionElements() {
    _libraryElement.topLevelFunctions = _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<TopLevelFunctionFragmentImpl>();
      // TODO(scheglov): link fragments.
      var element = TopLevelFunctionElementImpl(reference, fragments.first);

      element.deferReadResolution(
        _createDeferredReadResolutionCallback((reader) {
          // TODO(scheglov): remove cast
          reader._addTypeParameters2(element.typeParameters2.cast());

          element.returnType = reader.readRequiredType();
        }),
      );

      return element;
    });
  }

  void _readTopLevelFunctionFragments(LibraryFragmentImpl libraryFragment) {
    libraryFragment.functions = _reader.readTypedList(() {
      var id = _readFragmentId();
      var name = _readFragmentName();
      var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();
      var fragment = TopLevelFunctionFragmentImpl(name2: name, nameOffset: -1);
      idFragmentMap[id] = fragment;

      fragment.readModifiers(_reader);
      fragment.typeParameters = _readTypeParameters();
      fragment.parameters = _readParameters();

      fragment.deferReadResolution(() {
        var reader = ResolutionReader(
          _elementFactory,
          _referenceReader,
          _reader.fork(resolutionOffset),
        );
        _readTypeParameters2(
          fragment.libraryFragment,
          reader,
          fragment.typeParameters,
        );
        _readFormalParameters2(
          fragment.libraryFragment,
          reader,
          fragment.parameters,
        );
        _readFragmentMetadata(fragment, reader);
        fragment.returnType = reader.readRequiredType();
      });

      return fragment;
    });
  }

  TopLevelInferenceError? _readTopLevelInferenceError() {
    var kindIndex = _reader.readByte();
    var kind = TopLevelInferenceErrorKind.values[kindIndex];
    if (kind == TopLevelInferenceErrorKind.none) {
      return null;
    }
    return TopLevelInferenceError(
      kind: kind,
      arguments: _reader.readStringReferenceList(),
    );
  }

  void _readTopLevelVariableElements() {
    _libraryElement.topLevelVariables = _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<TopLevelVariableFragmentImpl>();
      // TODO(scheglov): link fragments.
      return TopLevelVariableElementImpl(reference, fragments.first);
    });
  }

  List<TopLevelVariableFragmentImpl> _readTopLevelVariableFragments() {
    return _reader.readTypedList(() {
      var id = _readFragmentId();
      var name = _readFragmentName();
      var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();
      var fragment = TopLevelVariableFragmentImpl(name2: name, nameOffset: -1);
      idFragmentMap[id] = fragment;

      fragment.readModifiers(_reader);

      fragment.deferReadResolution(() {
        var reader = ResolutionReader(
          _elementFactory,
          _referenceReader,
          _reader.fork(resolutionOffset),
        );
        reader.currentLibraryFragment = fragment.libraryFragment;
        _readFragmentMetadata(fragment, reader);
        fragment.type = reader.readRequiredType();
        if (reader.readOptionalExpression() case var initializer?) {
          fragment.constantInitializer = initializer;
          ConstantContextForExpressionImpl(fragment, initializer);
        }
      });

      return fragment;
    });
  }

  void _readTypeAliasElements() {
    _libraryElement.typeAliases = _reader.readTypedList(() {
      var reference = _readReference();
      var fragments = _readFragmentsById<TypeAliasFragmentImpl>();
      // TODO(scheglov): link fragments.
      var element = TypeAliasElementImpl(reference, fragments.first);
      return element;
    });
  }

  void _readTypeAliasFragments(LibraryFragmentImpl unitElement) {
    unitElement.typeAliases = _reader.readTypedList(() {
      var id = _readFragmentId();
      var name = _readFragmentName();
      var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();
      var fragment = TypeAliasFragmentImpl(name2: name, nameOffset: -1);
      idFragmentMap[id] = fragment;

      fragment.readModifiers(_reader);
      fragment.isFunctionTypeAliasBased = _reader.readBool();
      fragment.typeParameters = _readTypeParameters();

      fragment.deferReadResolution(() {
        var reader = ResolutionReader(
          _elementFactory,
          _referenceReader,
          _reader.fork(resolutionOffset),
        );
        _readTypeParameters2(
          fragment.libraryFragment,
          reader,
          fragment.typeParameters,
        );
        _readFragmentMetadata(fragment, reader);
        fragment.aliasedElement = reader._readAliasedElement(unitElement);
        fragment.aliasedType = reader.readRequiredType();
      });

      return fragment;
    });
  }

  List<TypeParameterFragmentImpl> _readTypeParameters() {
    return _reader.readTypedList(() {
      var fragmentName = _readFragmentName();
      var varianceEncoding = _reader.readByte();
      var variance = _decodeVariance(varianceEncoding);
      var element = TypeParameterFragmentImpl(
        name2: fragmentName,
        nameOffset: -1,
      );
      element.variance = variance;
      return element;
    });
  }

  void _readTypeParameters2(
    LibraryFragmentImpl unitElement,
    ResolutionReader reader,
    List<TypeParameterFragmentImpl> typeParameters,
  ) {
    reader._addTypeParameters(typeParameters);
    for (var typeParameter in typeParameters) {
      typeParameter.metadata = reader._readMetadata(unitElement: unitElement);
      typeParameter.bound = reader.readType();
      typeParameter.defaultType = reader.readType();
    }
  }

  LibraryFragmentImpl _readUnitElement({
    required LibraryFragmentImpl? containerUnit,
    required Source unitSource,
  }) {
    var resolutionOffset = _baseResolutionOffset + _reader.readUInt30();

    var unitElement = LibraryFragmentImpl(
      library: _libraryElement,
      source: unitSource,
      lineInfo: LineInfo([0]),
    );

    unitElement.deferReadResolution(() {
      var reader = ResolutionReader(
        _elementFactory,
        _referenceReader,
        _reader.fork(resolutionOffset),
      );

      reader.currentLibraryFragment = unitElement;

      for (var import in unitElement.libraryImports) {
        import.metadata = reader._readMetadata(unitElement: unitElement);
        var uri = import.uri;
        if (uri is DirectiveUriWithLibraryImpl) {
          uri.library2 = reader.libraryOfUri(uri.source.uri);
        }
      }

      for (var export in unitElement.libraryExports) {
        export.metadata = reader._readMetadata(unitElement: unitElement);
        var uri = export.uri;
        if (uri is DirectiveUriWithLibraryImpl) {
          uri.library2 = reader.libraryOfUri(uri.source.uri);
        }
      }

      for (var part in unitElement.parts) {
        part.metadata = reader._readMetadata(unitElement: unitElement);
      }
    });

    unitElement.isSynthetic = _reader.readBool();

    unitElement.libraryImports = _reader.readTypedList(() {
      return _readLibraryImport(containerUnit: unitElement);
    });

    unitElement.libraryExports = _reader.readTypedList(() {
      return _readLibraryExport(containerUnit: unitElement);
    });

    _readClassFragments(unitElement);
    _readEnumFragments(unitElement);
    _readExtensionFragments(unitElement);
    _readExtensionTypeFragments(unitElement);
    _readTopLevelFunctionFragments(unitElement);
    _readMixinFragments(unitElement);
    _readTypeAliasFragments(unitElement);

    unitElement.topLevelVariables = _readTopLevelVariableFragments();
    unitElement.getters = _readGetterFragments();
    unitElement.setters = _readSetterFragments();

    unitElement.parts = _reader.readTypedList(() {
      return _readPartInclude(containerUnit: unitElement);
    });

    return unitElement;
  }

  void _readVariableGetterSetterLinking() {
    _reader.readTypedList(() {
      var variable = _readReference().element as PropertyInducingElementImpl;

      var optionalGetter = _readOptionalReference()?.element;
      if (optionalGetter != null) {
        var getter = optionalGetter as GetterElementImpl;
        variable.getter2 = getter;
        getter.variable3 = variable;
      }

      var optionalSetter = _readOptionalReference()?.element;
      if (optionalSetter != null) {
        var setter = optionalSetter as SetterElementImpl;
        variable.setter2 = setter;
        setter.variable3 = variable;
      }
    });
  }

  static Variance? _decodeVariance(int index) {
    var tag = TypeParameterVarianceTag.values[index];
    switch (tag) {
      case TypeParameterVarianceTag.legacy:
        return null;
      case TypeParameterVarianceTag.unrelated:
        return Variance.unrelated;
      case TypeParameterVarianceTag.covariant:
        return Variance.covariant;
      case TypeParameterVarianceTag.contravariant:
        return Variance.contravariant;
      case TypeParameterVarianceTag.invariant:
        return Variance.invariant;
    }
  }
}

/// Helper for reading elements and types from their binary encoding.
class ResolutionReader {
  final LinkedElementFactory _elementFactory;
  final _ReferenceReader _referenceReader;
  final SummaryDataReader _reader;

  late LibraryFragmentImpl currentLibraryFragment;

  /// The stack of [TypeParameterElementImpl]s and [FormalParameterElementImpl]s
  /// that are available in the scope of [readElement] and [readType].
  ///
  /// This stack is shared with the client of the reader, and update mostly
  /// by the client. However it is also updated during [_readFunctionType].
  final List<ElementImpl> _localElements = [];

  ResolutionReader(this._elementFactory, this._referenceReader, this._reader);

  LibraryElementImpl libraryOfUri(Uri uri) {
    return _elementFactory.libraryOfUri2(uri);
  }

  bool readBool() {
    return _reader.readBool();
  }

  int readByte() {
    return _reader.readByte();
  }

  ConstructorElementMixin? readConstructorElementMixin() {
    var element2 = readElement() as ConstructorElement?;
    return element2?.asElement as ConstructorElementMixin?;
  }

  double readDouble() {
    return _reader.readDouble();
  }

  Element? readElement() {
    var kind = readEnum(ElementTag.values);
    switch (kind) {
      case ElementTag.null_:
        return null;
      case ElementTag.dynamic_:
        return DynamicElementImpl.instance;
      case ElementTag.never_:
        return NeverElementImpl.instance;
      case ElementTag.multiplyDefined:
        return null;
      case ElementTag.memberWithTypeArguments:
        var elementImpl = readElement() as ElementImpl;
        var enclosing = elementImpl.enclosingElement as InstanceElementImpl;

        var typeArguments = _readTypeList();
        var substitution = Substitution.fromPairs2(
          enclosing.typeParameters2,
          typeArguments,
        );

        if (elementImpl is ExecutableElementImpl) {
          return ExecutableMember.from(elementImpl, substitution);
        } else {
          elementImpl as FieldElementImpl;
          return FieldMember.from(elementImpl, substitution);
        }
      case ElementTag.elementImpl:
        var referenceIndex = _reader.readUInt30();
        var reference = _referenceReader.referenceOfIndex(referenceIndex);
        return _elementFactory.elementOfReference3(reference);
      case ElementTag.typeParameter:
        var index = _reader.readUInt30();
        return _localElements[index] as TypeParameterElementImpl;
      case ElementTag.formalParameter:
        var enclosing = readElement() as FunctionTypedElementImpl;
        var index = _reader.readUInt30();
        return enclosing.formalParameters[index];
    }
  }

  List<T> readElementList<T extends Element>() {
    return _reader.readTypedListCast<T>(readElement);
  }

  T readEnum<T extends Enum>(List<T> values) {
    return _reader.readEnum(values);
  }

  Map<K, V> readMap<K, V>({
    required K Function() readKey,
    required V Function() readValue,
  }) {
    return _reader.readMap(readKey: readKey, readValue: readValue);
  }

  MetadataImpl readMetadata() {
    return _readMetadata(unitElement: currentLibraryFragment);
  }

  List<T> readNodeList<T>() {
    return _readNodeList();
  }

  ExpressionImpl? readOptionalExpression() {
    if (_reader.readBool()) {
      return _readRequiredNode() as ExpressionImpl;
    } else {
      return null;
    }
  }

  FunctionTypeImpl? readOptionalFunctionType() {
    var type = readType();
    return type is FunctionTypeImpl ? type : null;
  }

  T? readOptionalObject<T>(T Function() read) {
    return _reader.readOptionalObject(read);
  }

  List<TypeImpl>? readOptionalTypeList() {
    if (_reader.readBool()) {
      return _readTypeList();
    } else {
      return null;
    }
  }

  TypeImpl readRequiredType() {
    return readType()!;
  }

  SourceRange readSourceRange() {
    var offset = readUInt30();
    var length = readUInt30();
    return SourceRange(offset, length);
  }

  String readStringReference() {
    return _reader.readStringReference();
  }

  List<String> readStringReferenceList() {
    return _reader.readStringReferenceList();
  }

  TypeImpl? readType() {
    var tag = _reader.readByte();
    if (tag == Tag.NullType) {
      return null;
    } else if (tag == Tag.DynamicType) {
      var type = DynamicTypeImpl.instance;
      return _readAliasElementArguments(type);
    } else if (tag == Tag.FunctionType) {
      var type = _readFunctionType();
      return _readAliasElementArguments(type);
    } else if (tag == Tag.InterfaceType) {
      var element = readElement() as InterfaceElementImpl;
      var typeArguments = _readTypeList();
      var nullability = _readNullability();
      var type = element.instantiateImpl(
        typeArguments: typeArguments,
        nullabilitySuffix: nullability,
      );
      return _readAliasElementArguments(type);
    } else if (tag == Tag.InterfaceType_noTypeArguments_none) {
      var element = readElement() as InterfaceElementImpl;
      var type = element.instantiateImpl(
        typeArguments: const [],
        nullabilitySuffix: NullabilitySuffix.none,
      );
      return _readAliasElementArguments(type);
    } else if (tag == Tag.InterfaceType_noTypeArguments_question) {
      var element = readElement() as InterfaceElementImpl;
      var type = element.instantiateImpl(
        typeArguments: const [],
        nullabilitySuffix: NullabilitySuffix.question,
      );
      return _readAliasElementArguments(type);
    } else if (tag == Tag.InvalidType) {
      var type = InvalidTypeImpl.instance;
      return _readAliasElementArguments(type);
    } else if (tag == Tag.NeverType) {
      var nullability = _readNullability();
      var type = NeverTypeImpl.instance.withNullability(nullability);
      return _readAliasElementArguments(type);
    } else if (tag == Tag.RecordType) {
      var type = _readRecordType();
      return _readAliasElementArguments(type);
    } else if (tag == Tag.TypeParameterType) {
      var element = readElement() as TypeParameterElementImpl;
      var nullability = _readNullability();
      var type = element.instantiate(nullabilitySuffix: nullability);
      return _readAliasElementArguments(type);
    } else if (tag == Tag.VoidType) {
      var type = VoidTypeImpl.instance;
      return _readAliasElementArguments(type);
    } else {
      throw UnimplementedError('$tag');
    }
  }

  List<T> readTypedList<T>(T Function() read) {
    return _reader.readTypedList(read);
  }

  int readUInt30() {
    return _reader.readUInt30();
  }

  int readUInt32() {
    return _reader.readUInt32();
  }

  void setOffset(int offset) {
    _reader.offset = offset;
  }

  void _addTypeParameters(List<TypeParameterFragmentImpl> typeParameters) {
    for (var typeParameter in typeParameters) {
      // TODO(scheglov): review later
      _localElements.add(typeParameter.element);
    }
  }

  void _addTypeParameters2(List<TypeParameterElementImpl> typeParameters) {
    for (var typeParameter in typeParameters) {
      _localElements.add(typeParameter);
    }
  }

  FragmentImpl? _readAliasedElement(LibraryFragmentImpl unitElement) {
    var tag = _reader.readByte();
    if (tag == AliasedElementTag.nothing) {
      return null;
    } else if (tag == AliasedElementTag.genericFunctionElement) {
      var typeParameters = _readTypeParameters(unitElement);
      var formalParameters = _readFormalParameters(unitElement);
      var returnType = readRequiredType();

      _localElements.length -= typeParameters.length;

      var fragment =
          GenericFunctionTypeFragmentImpl.forOffset(-1)
            ..typeParameters = typeParameters
            ..parameters = formalParameters
            ..returnType = returnType;
      unitElement.encloseElement(fragment);
      return fragment;
    } else {
      throw UnimplementedError('tag: $tag');
    }
  }

  TypeImpl _readAliasElementArguments(TypeImpl type) {
    var aliasElement = readElement();
    if (aliasElement != null) {
      aliasElement as TypeAliasElementImpl;
      var aliasArguments = _readTypeList();
      if (type is DynamicTypeImpl) {
        // TODO(scheglov): add support for `dynamic` aliasing
        return type;
      } else if (type is FunctionTypeImpl) {
        return FunctionTypeImpl(
          typeFormals: type.typeFormals,
          parameters: type.parameters,
          returnType: type.returnType,
          nullabilitySuffix: type.nullabilitySuffix,
          alias: InstantiatedTypeAliasElementImpl(
            element2: aliasElement,
            typeArguments: aliasArguments,
          ),
        );
      } else if (type is InterfaceTypeImpl) {
        return InterfaceTypeImpl(
          element: type.element3,
          typeArguments: type.typeArguments,
          nullabilitySuffix: type.nullabilitySuffix,
          alias: InstantiatedTypeAliasElementImpl(
            element2: aliasElement,
            typeArguments: aliasArguments,
          ),
        );
      } else if (type is RecordTypeImpl) {
        return RecordTypeImpl(
          positionalFields: type.positionalFields,
          namedFields: type.namedFields,
          nullabilitySuffix: type.nullabilitySuffix,
          alias: InstantiatedTypeAliasElementImpl(
            element2: aliasElement,
            typeArguments: aliasArguments,
          ),
        );
      } else if (type is TypeParameterTypeImpl) {
        return TypeParameterTypeImpl(
          element3: type.element3,
          nullabilitySuffix: type.nullabilitySuffix,
          alias: InstantiatedTypeAliasElementImpl(
            element2: aliasElement,
            typeArguments: aliasArguments,
          ),
        );
      } else if (type is VoidTypeImpl) {
        // TODO(scheglov): add support for `void` aliasing
        return type;
      } else {
        throw UnimplementedError('${type.runtimeType}');
      }
    }
    return type;
  }

  List<FormalParameterFragmentImpl> _readFormalParameters(
    LibraryFragmentImpl? unitElement,
  ) {
    return readTypedList(() {
      var kindIndex = _reader.readByte();
      var kind = _formalParameterKind(kindIndex);
      var isDefault = _reader.readBool();
      var hasImplicitType = _reader.readBool();
      var isInitializingFormal = _reader.readBool();
      var typeParameters = _readTypeParameters(unitElement);
      var type = readRequiredType();
      var name = _readFragmentName();
      if (!isDefault) {
        FormalParameterFragmentImpl element;
        if (isInitializingFormal) {
          element = FieldFormalParameterFragmentImpl(
            nameOffset: -1,
            name2: name,
            nameOffset2: null,
            parameterKind: kind,
          )..type = type;
        } else {
          element = FormalParameterFragmentImpl(
            nameOffset: -1,
            name2: name,
            nameOffset2: null,
            parameterKind: kind,
          )..type = type;
        }
        element.hasImplicitType = hasImplicitType;
        element.typeParameters = typeParameters;
        element.parameters = _readFormalParameters(unitElement);
        // TODO(scheglov): reuse for formal parameters
        _localElements.length -= typeParameters.length;
        if (unitElement != null) {
          element.metadata = _readMetadata(unitElement: unitElement);
        }
        return element;
      } else {
        var element = DefaultParameterFragmentImpl(
          nameOffset: -1,
          name2: name,
          nameOffset2: null,
          parameterKind: kind,
        )..type = type;
        element.hasImplicitType = hasImplicitType;
        element.typeParameters = typeParameters;
        element.parameters = _readFormalParameters(unitElement);
        // TODO(scheglov): reuse for formal parameters
        _localElements.length -= typeParameters.length;
        if (unitElement != null) {
          element.metadata = _readMetadata(unitElement: unitElement);
        }
        return element;
      }
    });
  }

  String? _readFragmentName() {
    return _reader.readOptionalStringReference();
  }

  // TODO(scheglov): Optimize for write/read of types without type parameters.
  FunctionTypeImpl _readFunctionType() {
    // TODO(scheglov): reuse for formal parameters
    var typeParameters = _readTypeParameters(null);
    var returnType = readRequiredType();
    var formalParameters = _readFormalParameters(null);

    var nullability = _readNullability();

    _localElements.length -= typeParameters.length;

    return FunctionTypeImpl(
      typeFormals: typeParameters,
      parameters: formalParameters.map((f) => f.asElement2).toList(),
      returnType: returnType,
      nullabilitySuffix: nullability,
    );
  }

  InterfaceTypeImpl _readInterfaceType() {
    return readType() as InterfaceTypeImpl;
  }

  List<InterfaceTypeImpl> _readInterfaceTypeList() {
    return readTypedList(_readInterfaceType);
  }

  MetadataImpl _readMetadata({required LibraryFragmentImpl unitElement}) {
    currentLibraryFragment = unitElement;
    var annotations = readTypedList(() {
      var ast = _readRequiredNode() as AnnotationImpl;
      return ElementAnnotationImpl(unitElement)
        ..annotationAst = ast
        ..element2 = ast.element2;
    });

    return MetadataImpl(annotations);
  }

  List<T> _readNodeList<T>() {
    return readTypedList(() {
      return _readRequiredNode() as T;
    });
  }

  NullabilitySuffix _readNullability() {
    var index = _reader.readByte();
    return NullabilitySuffix.values[index];
  }

  InterfaceType? _readOptionalInterfaceType() {
    return readType() as InterfaceType?;
  }

  RecordTypeImpl _readRecordType() {
    var positionalFields = readTypedList(() {
      return RecordTypePositionalFieldImpl(type: readRequiredType());
    });

    var namedFields = readTypedList(() {
      return RecordTypeNamedFieldImpl(
        name: _reader.readStringReference(),
        type: readRequiredType(),
      );
    });

    var nullabilitySuffix = _readNullability();

    return RecordTypeImpl(
      positionalFields: positionalFields,
      namedFields: namedFields,
      nullabilitySuffix: nullabilitySuffix,
    );
  }

  AstNode _readRequiredNode() {
    var astReader = AstBinaryReader(reader: this);
    return astReader.readNode();
  }

  List<TypeImpl> _readTypeList() {
    return readTypedList(() {
      return readRequiredType();
    });
  }

  List<TypeParameterFragmentImpl> _readTypeParameters(
    LibraryFragmentImpl? unitElement,
  ) {
    var typeParameters = readTypedList(() {
      var fragmentName = _readFragmentName();
      var typeParameterFragment = TypeParameterFragmentImpl(
        name2: fragmentName,
        nameOffset: -1,
      );
      var typeParameterElement = TypeParameterElementImpl(
        firstFragment: typeParameterFragment,
        name3: typeParameterFragment.name2,
      );
      _localElements.add(typeParameterElement);
      // TODO(scheglov): why not element?
      return typeParameterFragment;
    });

    for (var typeParameter in typeParameters) {
      typeParameter.bound = readType();
      if (unitElement != null) {
        typeParameter.metadata = _readMetadata(unitElement: unitElement);
      }
    }
    return typeParameters;
  }

  static ParameterKind _formalParameterKind(int encoding) {
    if (encoding == Tag.ParameterKindRequiredPositional) {
      return ParameterKind.REQUIRED;
    } else if (encoding == Tag.ParameterKindOptionalPositional) {
      return ParameterKind.POSITIONAL;
    } else if (encoding == Tag.ParameterKindRequiredNamed) {
      return ParameterKind.NAMED_REQUIRED;
    } else if (encoding == Tag.ParameterKindOptionalNamed) {
      return ParameterKind.NAMED;
    } else {
      throw StateError('Unexpected parameter kind encoding: $encoding');
    }
  }
}

/// Information that we need to know about each library before reading it,
/// and without reading it.
///
/// Specifically, the [offset] allows us to know the location of each library,
/// so that when we need to read this library, we know where it starts without
/// reading previous libraries.
class _LibraryHeader {
  final Uri uri;
  final int offset;

  _LibraryHeader({required this.uri, required this.offset});
}

class _ReferenceReader {
  final LinkedElementFactory elementFactory;
  final SummaryDataReader _reader;
  late final Uint32List _parents;
  late final Uint32List _names;
  late final List<Reference?> _references;

  _ReferenceReader(this.elementFactory, this._reader, int offset) {
    _reader.offset = offset;
    _parents = _reader.readUInt30List();
    _names = _reader.readUInt30List();
    assert(_parents.length == _names.length);

    _references = List.filled(_names.length, null);
  }

  Reference referenceOfIndex(int index) {
    var reference = _references[index];
    if (reference != null) {
      return reference;
    }

    if (index == 0) {
      reference = elementFactory.rootReference;
      _references[index] = reference;
      return reference;
    }

    var nameIndex = _names[index];
    var name = _reader.stringOfIndex(nameIndex);

    var parentIndex = _parents[index];
    var parent = referenceOfIndex(parentIndex);

    reference = parent.getChild(name);
    _references[index] = reference;

    return reference;
  }
}
