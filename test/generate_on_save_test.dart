import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_serverpod/lumide_serverpod.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  const debounce = Duration(milliseconds: 10);
  final serverRoot = path.join(path.current, 'app', 'app_server');
  final modelUri = _uri(serverRoot, ['lib', 'src', 'models', 'user.spy.yaml']);
  final endpointPath = path.join(serverRoot, 'lib', 'src', 'greeting.dart');

  Future<void> settle() => Future<void>.delayed(debounce * 4);

  GenerateOnSave watcher({
    required List<String> runs,
    bool Function()? enabled,
    Map<String, String> files = const {},
    Future<void> Function()? generate,
  }) {
    final generateOnSave = GenerateOnSave(
      debounce: debounce,
      serverRootFor: (filePath) =>
          switch (path.isWithin(serverRoot, filePath)) {
        true => serverRoot,
        false => null,
      },
      shouldGenerate: (_) async => enabled?.call() ?? true,
      generate: (root) async {
        runs.add(root);
        await generate?.call();
      },
      readFile: (filePath) async => files[filePath],
    );
    addTearDown(generateOnSave.dispose);
    return generateOnSave;
  }

  test('generates once for a burst of model saves', () async {
    final runs = <String>[];
    final generateOnSave = watcher(runs: runs);

    await generateOnSave.handleSave(modelUri);
    await generateOnSave.handleSave(modelUri);
    await generateOnSave.handleSave(
      _uri(serverRoot, ['lib', 'src', 'models', 'post.spy']),
    );
    await settle();

    expect(runs, [serverRoot]);
  });

  test('generates for endpoints but not for other Dart files', () async {
    final runs = <String>[];
    final helperPath = path.join(serverRoot, 'lib', 'src', 'helper.dart');
    final generateOnSave = watcher(runs: runs, files: {
      endpointPath: 'class GreetingEndpoint extends Endpoint {}',
      helperPath: 'int add(int a, int b) => a + b;',
    });

    await generateOnSave.handleSave(Uri.file(helperPath).toString());
    await settle();
    expect(runs, isEmpty);

    await generateOnSave.handleSave(Uri.file(endpointPath).toString());
    await settle();
    expect(runs, [serverRoot]);
  });

  test('ignores generated code, files outside servers and other URIs',
      () async {
    final runs = <String>[];
    final generatedPath = path.join(
      serverRoot,
      'lib',
      'src',
      'generated',
      'endpoints.dart',
    );
    final generateOnSave = watcher(runs: runs, files: {
      generatedPath: 'class Endpoints extends Endpoint {}',
    });

    await generateOnSave.handleSave(Uri.file(generatedPath).toString());
    await generateOnSave.handleSave(
      _uri(path.current, ['other', 'model.spy.yaml']),
    );
    await generateOnSave.handleSave('untitled:model.spy.yaml');
    await settle();

    expect(runs, isEmpty);
  });

  test('respects the setting', () async {
    final runs = <String>[];
    final generateOnSave = watcher(runs: runs, enabled: () => false);

    await generateOnSave.handleSave(modelUri);
    await settle();

    expect(runs, isEmpty);
  });

  test('queues one more run for saves during generation', () async {
    final runs = <String>[];
    final firstRun = Completer<void>();
    final generateOnSave = watcher(
      runs: runs,
      generate: () async {
        if (runs.length == 1) await firstRun.future;
      },
    );

    await generateOnSave.handleSave(modelUri);
    await settle();
    await generateOnSave.handleSave(modelUri);
    await settle();
    await generateOnSave.handleSave(modelUri);
    await settle();
    firstRun.complete();
    await settle();

    expect(runs, [serverRoot, serverRoot]);
  });

  test('generates for endpoints extending other endpoints', () async {
    final runs = <String>[];
    final generateOnSave = watcher(runs: runs, files: {
      endpointPath: 'class EmailIdpEndpoint extends EmailIdpBaseEndpoint {}\n',
    });

    await generateOnSave.handleSave(Uri.file(endpointPath).toString());
    await settle();

    expect(runs, [serverRoot]);
  });

  test('generates once more when a file stops being an endpoint', () async {
    final runs = <String>[];
    final files = {endpointPath: 'class A extends Endpoint {}'};
    final generateOnSave = watcher(runs: runs, files: files);

    await generateOnSave.handleSave(Uri.file(endpointPath).toString());
    await settle();
    files[endpointPath] = 'class A {}';
    await generateOnSave.handleSave(Uri.file(endpointPath).toString());
    await settle();
    await generateOnSave.handleSave(Uri.file(endpointPath).toString());
    await settle();

    expect(runs, [serverRoot, serverRoot]);
  });

  test('generates when a model file is created, deleted or renamed', () async {
    final runs = <String>[];
    final generateOnSave = watcher(runs: runs);

    generateOnSave.handleFileChange(
      LumideFileChange(uri: modelUri, type: LumideFileChangeType.deleted),
    );
    await settle();
    generateOnSave.handleFileChange(
      LumideFileChange(uri: modelUri, type: LumideFileChangeType.changed),
    );
    generateOnSave.handleFileChange(
      LumideFileChange(
        uri: _uri(serverRoot, ['README.md']),
        type: LumideFileChangeType.created,
      ),
    );
    await settle();

    expect(runs, [serverRoot]);
  });

  test('checks the setting again before a queued run', () async {
    final runs = <String>[];
    final firstRun = Completer<void>();
    var enabled = true;
    final generateOnSave = watcher(
      runs: runs,
      enabled: () => enabled,
      generate: () async {
        if (runs.length == 1) await firstRun.future;
      },
    );

    await generateOnSave.handleSave(modelUri);
    await settle();
    await generateOnSave.handleSave(modelUri);
    await settle();
    enabled = false;
    firstRun.complete();
    await settle();

    expect(runs, [serverRoot]);
  });

  group('isEndpointSource', () {
    test('finds the endpoints of the Serverpod template', () {
      for (final source in [
        'class GreetingEndpoint extends Endpoint {',
        'class EmailIdpEndpoint extends EmailIdpBaseEndpoint {}',
        'class JwtRefreshEndpoint extends RefreshJwtTokensEndpoint {}',
        'class A extends auth.Endpoint {}',
        'class Paged<T extends Object> extends Endpoint {}',
      ]) {
        expect(GenerateOnSave.isEndpointSource(source), isTrue, reason: source);
      }
    });

    test('ignores other classes', () {
      for (final source in [
        'class RootRoute extends WidgetRoute {',
        'class EndpointHelper {}',
        'class A extends EndpointDispatch {}',
      ]) {
        expect(GenerateOnSave.isEndpointSource(source), isFalse,
            reason: source);
      }
    });
  });
}

String _uri(String root, List<String> segments) =>
    Uri.file(path.joinAll([root, ...segments])).toString();
