import 'package:lumide_api/lumide_api.dart';
import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service.dart';

/// Stack frames, variables and evaluation of a paused isolate, in the shape
/// Lumide's debugger shows them.
///
/// Frames and variable references stay valid until [clear], which the
/// debugger calls whenever the isolate resumes.
class DebugInspector {
  final Map<int, Frame> _framesById = {};
  final Map<int, _VariableReference> _references = {};
  int _nextReference = _firstVariableReference;

  /// Frame ids double as scope ids; variable references start above them.
  static const _firstVariableReference = 1 << 20;

  void clear() {
    _framesById.clear();
    _references.clear();
    _nextReference = _firstVariableReference;
  }

  Future<List<LumideDebugStackFrame>> stackFrames(
    VmService service,
    String isolateId,
  ) async {
    final stack = await service.getStack(isolateId);
    final frames = stack.frames ?? const <Frame>[];
    clear();

    final fileUris = await _fileUris(service, isolateId, [
      for (final frame in frames)
        if (frame.location?.script?.uri case final uri?) uri,
    ]);

    final result = <LumideDebugStackFrame>[];
    for (var index = 0; index < frames.length; index++) {
      final frame = frames[index];
      final location = frame.location;
      final scriptUri = location?.script?.uri;
      final line = location?.line;
      if (scriptUri == null || scriptUri.isEmpty || line == null) continue;

      final frameId = frame.index ?? index;
      _framesById[frameId] = frame;
      final sourceUri = fileUris[scriptUri] ?? scriptUri;
      result.add(
        LumideDebugStackFrame(
          id: frameId,
          name: frame.function?.name ?? '<frame>',
          sourceUri: sourceUri,
          sourceName: path.url.basename(Uri.parse(sourceUri).path),
          line: line,
          column: location?.column ?? 1,
        ),
      );
    }
    return result;
  }

  List<LumideDebugScope> scopes(int frameId) {
    final frame = _framesById[frameId];
    if (frame == null) return const [];
    return [
      LumideDebugScope(
        id: frameId,
        name: 'Locals',
        presentationHint: 'locals',
        namedVariables: frame.vars?.length ?? 0,
      ),
    ];
  }

  Future<List<LumideDebugVariable>> variables(
    VmService service,
    String isolateId,
    int reference,
  ) async {
    if (_framesById[reference] case final frame?) {
      return [
        for (final variable in frame.vars ?? const <BoundVariable>[])
          await _variable(
            service,
            isolateId,
            name: variable.name ?? '<unnamed>',
            value: variable.value,
            evaluateName: variable.name,
          ),
      ];
    }

    final entry = _references[reference];
    if (entry == null) return const [];
    return _children(service, isolateId, entry);
  }

  Future<LumideDebugEvaluationResult> evaluate(
    VmService service,
    String isolateId,
    String expression, {
    int? frameId,
  }) async {
    try {
      final response = await service.evaluateInFrame(
        isolateId,
        frameId ?? 0,
        expression,
        disableBreakpoints: true,
      );
      return switch (response) {
        InstanceRef instance => LumideDebugEvaluationResult(
            result: await describe(service, isolateId, instance),
            type: instance.classRef?.name,
            variablesReference: _referenceFor(instance, expression),
          ),
        ErrorRef error => LumideDebugEvaluationResult(
            result: error.message ?? 'Evaluation failed',
            type: error.kind,
          ),
        _ => LumideDebugEvaluationResult(result: response.toString()),
      };
    } catch (error) {
      return LumideDebugEvaluationResult(
        result: 'Evaluation failed: $error',
        type: 'error',
      );
    }
  }

  /// [value] as text, with long strings fetched in full.
  Future<String> describe(
    VmService service,
    String isolateId,
    Object? value,
  ) async {
    return switch (value) {
      null => 'null',
      InstanceRef(kind: InstanceKind.kNull) => 'null',
      InstanceRef(valueAsStringIsTruncated: true, :final id?) =>
        await _fullString(service, isolateId, id) ?? '${value.valueAsString}…',
      InstanceRef(:final valueAsString?) => switch (value.kind) {
          InstanceKind.kString => '"$valueAsString"',
          _ => valueAsString,
        },
      InstanceRef(:final length?) when _isCollection(value) =>
        '${value.classRef?.name ?? value.kind} (length: $length)',
      InstanceRef(:final classRef) =>
        'Instance of ${classRef?.name ?? value.kind ?? 'object'}',
      Sentinel(:final valueAsString?) => valueAsString,
      ObjRef(:final id?) => 'Object $id',
      _ => value.toString(),
    };
  }

  Future<List<LumideDebugVariable>> _children(
    VmService service,
    String isolateId,
    _VariableReference entry,
  ) async {
    final id = entry.instance.id;
    if (id == null) return const [];
    final object = await service.getObject(isolateId, id);
    if (object is! Instance) return const [];
    final parent = entry.evaluateName;

    return [
      for (final field in object.fields ?? const <BoundField>[])
        await _variable(
          service,
          isolateId,
          name: '${field.name ?? field.decl?.name ?? '<field>'}',
          value: field.value,
          evaluateName: switch ((parent, field.name)) {
            (final parent?, final String name) when _isIdentifier(name) =>
              '$parent.$name',
            _ => null,
          },
        ),
      for (final (index, element) in (object.elements ?? const []).indexed)
        await _variable(
          service,
          isolateId,
          name: '[$index]',
          value: element,
          evaluateName: switch (parent) {
            final parent? => '$parent[$index]',
            null => null,
          },
        ),
      for (final association in object.associations ?? const <MapAssociation>[])
        await _variable(
          service,
          isolateId,
          name: '[${await describe(service, isolateId, association.key)}]',
          value: association.value,
        ),
    ];
  }

  Future<LumideDebugVariable> _variable(
    VmService service,
    String isolateId, {
    required String name,
    required Object? value,
    String? evaluateName,
  }) async {
    return LumideDebugVariable(
      name: name,
      value: await describe(service, isolateId, value),
      type: switch (value) {
        InstanceRef(:final classRef?) => classRef.name,
        Sentinel(:final kind?) => kind,
        _ => null,
      },
      evaluateName: evaluateName,
      variablesReference: switch (value) {
        final InstanceRef instance => _referenceFor(instance, evaluateName),
        _ => null,
      },
    );
  }

  int? _referenceFor(InstanceRef instance, String? evaluateName) {
    final expandable = switch (instance.kind) {
      InstanceKind.kPlainInstance ||
      InstanceKind.kRecord ||
      InstanceKind.kList ||
      InstanceKind.kSet ||
      InstanceKind.kMap =>
        true,
      _ => false,
    };
    if (!expandable || instance.id == null) return null;
    final reference = _nextReference++;
    _references[reference] = _VariableReference(instance, evaluateName);
    return reference;
  }

  Future<String?> _fullString(
    VmService service,
    String isolateId,
    String objectId,
  ) async {
    try {
      final object = await service.getObject(isolateId, objectId);
      if (object case Instance(:final valueAsString?)) return valueAsString;
    } catch (_) {
      // The object was collected; the truncated text is shown instead.
    }
    return null;
  }

  /// `file:` URIs for the `package:` URIs among [scriptUris], so Lumide
  /// opens the right file for each frame.
  static Future<Map<String, String>> _fileUris(
    VmService service,
    String isolateId,
    List<String> scriptUris,
  ) async {
    final packageUris = [
      for (final uri in scriptUris.toSet())
        if (uri.startsWith('package:')) uri,
    ];
    if (packageUris.isEmpty) return const {};
    try {
      final resolved =
          await service.lookupResolvedPackageUris(isolateId, packageUris);
      final uris = resolved.uris ?? const <String?>[];
      return {
        for (final (index, packageUri) in packageUris.indexed)
          if (index < uris.length)
            if (uris[index] case final String fileUri) packageUri: fileUri,
      };
    } catch (_) {
      return const {};
    }
  }

  static bool _isCollection(InstanceRef value) => switch (value.kind) {
        InstanceKind.kList || InstanceKind.kSet || InstanceKind.kMap => true,
        _ => false,
      };

  static bool _isIdentifier(String name) => _identifier.hasMatch(name);

  static final _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');
}

class _VariableReference {
  const _VariableReference(this.instance, this.evaluateName);

  final InstanceRef instance;
  final String? evaluateName;
}
