import 'dart:async';
import 'dart:collection';

import 'package:analyzer/dart/element/element2.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:gql_code_builder/serializer.dart';
import 'package:path/path.dart' as p;
import 'package:glob/glob.dart';

import 'src/utils/config.dart';
import 'src/utils/locations.dart';
import 'src/utils/writer.dart';
import 'src/allocators/pick_allocator.dart';

Builder serializerBuilder(
  BuilderOptions options,
) =>
    SerializerBuilder(options.config);

class SerializerBuilder implements Builder {
  BuilderConfig config;

  SerializerBuilder(Map<String, dynamic> config)
      : config = BuilderConfig(config);

  final outputFileName = 'serializers.gql.dart';

  // create a path for the serializers output in same directory as schema
  List<String> pathSegments(AssetId schemaId) =>
      outputAssetId(schemaId, '', config.outputDir).pathSegments
        ..removeLast()
        ..add(outputFileName);

  @override
  Map<String, List<String>> get buildExtensions {
    final inputToOutputMap = <String, List<String>>{};
    if (config.schemaId != null) {
      // buildExtensions already include the 'lib' path segment, so we must remove it here
      inputToOutputMap[r'$lib$'] = [
        p.joinAll(pathSegments(config.schemaId!).skip(1))
      ];
    }

    if (config.schemaIds != null) {
      for (final schemaId in config.schemaIds!) {
        inputToOutputMap[schemaId.path] = [p.joinAll(pathSegments(schemaId))];
      }
    }

    return inputToOutputMap;
  }

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    if (buildStep.inputId.path == r'lib/$lib$' && config.schemaId != null) {
      final _generatedFiles = Glob('lib/**.gql.dart');
      final _excludeFiles = <Glob>[];
      if (config.schemaIds != null) {
        for (final schemaId in config.schemaIds!) {
          var dirPath = p.dirname(schemaId.path);
          _excludeFiles.add(Glob('$dirPath/**.gql.dart'));
        }
      }
      await buildSchema(
          buildStep, config.schemaId!, _generatedFiles, _excludeFiles);
    }

    if (config.schemaIds != null) {
      for (final schemaId in config.schemaIds!) {
        if (schemaId == buildStep.inputId) {
          var dirPath = p.dirname(schemaId.path);
          final _generatedFiles = Glob('$dirPath/**.gql.dart');
          await buildSchema(buildStep, schemaId, _generatedFiles, []);
          break;
        }
      }
    }
  }

  FutureOr<void> buildSchema(BuildStep buildStep, AssetId schemaId,
      Glob generatedFiles, List<Glob> excludeFiles) async {
    /// BuiltValue classes with serializers. These will be added automatically
    /// using `@SerializersFor`.
    final builtClasses =
        SplayTreeSet<ClassElement2>((a, b) => a.name3!.compareTo(b.name3!));

    /// Non BuiltValue classes with serializers (i.e. inline fragment classes).
    /// These need to be added manually since `@SerializersFor` only recognizes
    /// BuiltValue classes.
    final nonBuiltClasses =
        SplayTreeSet<ClassElement2>((a, b) => a.name3!.compareTo(b.name3!));

    final excludeFileIds = <String, AssetId>{};
    for (final excludeGlob in excludeFiles) {
      await for (final fileAssetId in buildStep.findAssets(excludeGlob)) {
        excludeFileIds[fileAssetId.path] = fileAssetId;
      }
    }

    await for (final input in buildStep.findAssets(generatedFiles)) {
      if (excludeFileIds.containsKey(input.path)) continue;
      final lib = await buildStep.resolver.libraryFor(input);
      final classes = extractClassesToGenerateSerializersFor(lib);
      builtClasses.addAll(classes.builtClasses);
      nonBuiltClasses.addAll(classes.nonBuiltClasses);
    }

    final additionalSerializers = <Expression>{
      // GraphQL Operation serializer
      refer(
        'OperationSerializer',
        'package:gql_code_builder_serializers/gql_code_builder_serializers.dart',
      ).call([]),
      // User-defined custom serializers
      ...config.customSerializers.map((ref) => ref.call([])),
      // Serializers from data classes that aren't caught by `@SerializersFor`
      ...nonBuiltClasses.map<Expression>(
        (c) =>
            refer(c.name3!, c.library2.uri.toString()).property('serializer'),
      ),
    };

    // if the schema is defined in a different package
    // we need to import the serializers from that package
    // and add them to the serializers of this package
    final isExternalSchema = schemaId.package != buildStep.inputId.package;

    final externalSerializersExpression = isExternalSchema
        ? refer('serializers',
                _externalSchemaSerializersImport(schemaId, config))
            .property('serializers')
        : null;

    if (isExternalSchema) {
      final externalSchemaId =
          outputAssetId(schemaId, schemaExtension, config.outputDir);

      final externalSchemaLibrary =
          await buildStep.resolver.libraryFor(externalSchemaId);

      final externalSchemaClasses =
          extractClassesToGenerateSerializersFor(externalSchemaLibrary);

      builtClasses.addAll(externalSchemaClasses.builtClasses);
      nonBuiltClasses.addAll(externalSchemaClasses.nonBuiltClasses);
    }

    // Gather input object classes (convention: names ending with 'Input')
    final inputObjectClasses = builtClasses.where((c) => (c.name3?.endsWith('Input') ?? false)).toList(growable: false);

    var library = buildFerrySerializerLibrary(
      builtClasses,
      outputFileName.replaceFirst('.gql.dart', '.gql.g.dart'),
      additionalSerializers,
      externalSerializers: externalSerializersExpression,
      inputObjectClasses: inputObjectClasses,
    );

    final allocator = PickAllocator(doNotPick: [
      'package:built_value/serializer.dart',
    ], include: [
      'package:built_collection/built_collection.dart',
      'package:ferry_exec/ferry_exec.dart',
      ...config.typeOverrides.values.map((ref) => ref.url).whereType<String>(),
    ], aliasedImports: {
      if (isExternalSchema)
        _externalSchemaSerializersImport(schemaId, config):
            '_\$external_serializers',
    });

    final outputId = AssetId(
      buildStep.inputId.package,
      p.joinAll(pathSegments(schemaId)),
    );

    await writeDocument(outputId, library, allocator, buildStep, config.format);
  }
}

String _externalSchemaSerializersImport(
    AssetId schemaId, BuilderConfig config) {
  final outPutId = outputAssetId(schemaId, schemaExtension, config.outputDir);

  final serializersPathSegments = outPutId.pathSegments
    ..removeAt(0)
    ..removeLast()
    ..add('serializers.gql.dart');

  final outPutPath = p.joinAll(serializersPathSegments);

  return 'package:${outPutId.package}/$outPutPath';
}

bool hasSerializer(ClassElement2 c) => c.fields2.any((field) =>
    field.isStatic &&
    field.name3 == 'serializer' &&
    field.type.element3?.name3 == 'Serializer' &&
    field.type.element3?.library2?.uri.toString() ==
        'package:built_value/serializer.dart');

bool isBuiltValue(ClassElement2 c) => c.allSupertypes.any((interface) =>
    (interface.element3.name3 == 'Built' ||
        interface.element3.name3 == 'EnumClass') &&
    interface.element3.library2.uri.toString() ==
        'package:built_value/built_value.dart');

typedef ClassesToGenerateSerializersFor = ({
  Set<ClassElement2> builtClasses,
  Set<ClassElement2> nonBuiltClasses
});

ClassesToGenerateSerializersFor extractClassesToGenerateSerializersFor(
    LibraryElement2 externalSchemaLibrary) {
  final builtClasses = externalSchemaLibrary.classes
      .where((c) => hasSerializer(c) && isBuiltValue(c))
      .toSet();

  final nonBuiltClasses = externalSchemaLibrary.classes
      .where(
        (c) => hasSerializer(c) && !isBuiltValue(c),
      )
      .toSet();

  return (
    builtClasses: builtClasses,
    nonBuiltClasses: nonBuiltClasses,
  );
}

// Local implementation of serializer library builder with inline addBuilderFactory support
Library buildFerrySerializerLibrary(
  Set<ClassElement2> builtClasses,
  String partDirectiveUrl,
  Set<Expression> additionalSerializers, {
  Expression? externalSerializers,
  required List<ClassElement2> inputObjectClasses,
}) {
  // Build the builder base expression: _$serializers.toBuilder()
  Expression builderExpr = refer(r'_$serializers').property('toBuilder').call([]);

  // Apply additional serializers (OperationSerializer, custom, holder serializer, etc.)
  builderExpr = builderExpr.withCustomSerializers(additionalSerializers);

  // If there are external serializers, add them
  if (externalSerializers != null) {
    builderExpr = builderExpr.cascade('addAll').call([externalSerializers]);
  }

  // Add explicit addBuilderFactory cascades for each input object list type
  if (inputObjectClasses.isNotEmpty) {
    for (final c in inputObjectClasses) {
      final fullTypeListOfInput = refer('FullType', 'package:built_value/serializer.dart').constInstance([
        refer('BuiltList', 'package:built_collection/built_collection.dart'),
        literalConstList([
          refer('FullType', 'package:built_value/serializer.dart').constInstance([
            refer(c.name3!, c.library2.uri.toString()),
          ]),
        ]),
      ]);

      final listBuilderFactory = Method((m) {
        m
          ..lambda = true
          ..body = TypeReference((t) => t
            ..symbol = 'ListBuilder'
            ..url = 'package:built_collection/built_collection.dart'
            ..types.add(refer(c.name3!, c.library2.uri.toString()))).call([]).code;
      }).closure;

      builderExpr = builderExpr.cascade('addBuilderFactory').call([
        fullTypeListOfInput,
        listBuilderFactory,
      ]);
    }
  }

  // Add StandardJsonPlugin
  builderExpr = builderExpr.cascade('addPlugin').call([
    refer('StandardJsonPlugin', 'package:built_value/standard_json_plugin.dart').call([]),
  ]);

  // Build library
  return Library(
    (b) => b
      ..directives.add(Directive.part(partDirectiveUrl))
      ..body.addAll([
        declareFinal(
          '_serializersBuilder',
          type: refer('SerializersBuilder', 'package:built_value/serializer.dart'),
        ).assign(builderExpr).statement,
        refer('@SerializersFor', 'package:built_value/serializer.dart').call([
          literalList(
            builtClasses.map<Reference>((c) => refer(c.name3!, c.library2.uri.toString())).toList()
              ..sort((a, b) => a.symbol!.compareTo(b.symbol!)),
          )
        ]),
        declareFinal(
          'serializers',
          type: refer('Serializers', 'package:built_value/serializer.dart'),
        ).assign(refer('_serializersBuilder').property('build').call([])).statement,
      ]),
  );
}

extension FerryExpressionHelpers on Expression {
  Expression applyIf(bool condition, Expression Function(Expression) wrap) => condition ? wrap(this) : this;

  Expression withCustomSerializers(Set<Expression> customSerializers) =>
      customSerializers.fold(this, (exp, serializer) => exp.cascade('add').call([serializer]));
}
