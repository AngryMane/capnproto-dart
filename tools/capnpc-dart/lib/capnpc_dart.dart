library;

export 'src/schema/schema_model.dart';
export 'src/schema/schema_reader.dart' show readCodeGeneratorRequest;
export 'src/generator/dart_generator.dart' show generateDartFile;
export 'src/codegen.dart' show readSchemaRequest, generateDartFiles;
export 'src/compat/schema_capture.dart' show captureOldSchema;
export 'src/compat/compat_checker.dart' show checkCompatibility;
