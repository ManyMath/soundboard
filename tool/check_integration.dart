import 'dart:convert';
import 'dart:io';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent;
  final manifest =
      jsonDecode(File('${root.path}/tool/integration.json').readAsStringSync())
          as Map<String, dynamic>;
  final pins = manifest['dependencies'] as Map<String, dynamic>;
  final configFile = File('${root.path}/.dart_tool/package_config.json');
  final resolved =
      (jsonDecode(configFile.readAsStringSync())['packages'] as List)
          .cast<Map<String, dynamic>>();
  final workspace =
      loadYaml(File('${root.path}/pubspec.yaml').readAsStringSync()) as YamlMap;
  final specs = <YamlMap>[];
  for (final entry in pins.entries) {
    final name = entry.key;
    final pin = entry.value as Map<String, dynamic>;
    final override = workspace['dependency_overrides'][name]['git'] as YamlMap;
    final repository = Uri.parse(pin['repository'] as String);
    final url = 'ssh://git@${repository.host}:2222${repository.path}.git';
    if (override['url'] != url ||
        override['ref'] != pin['revision'] ||
        override['path'] != pin['path']) {
      throw StateError('$name manifest and immutable override differ');
    }
    final package = resolved.singleWhere((p) => p['name'] == name);
    final directory = Directory.fromUri(
      configFile.uri.resolve(package['rootUri'] as String),
    );
    final result = await Process.run('git', [
      '-C',
      directory.path,
      'rev-parse',
      'HEAD',
    ]);
    if (result.exitCode != 0 ||
        result.stdout.toString().trim() != pin['revision']) {
      throw StateError('$name resolved source is not the reviewed revision');
    }
    final top = await Process.run('git', [
      '-C',
      directory.path,
      'rev-parse',
      '--show-toplevel',
    ]);
    if (top.exitCode != 0) throw StateError('$name has no Git checkout root');
    final expectedDirectory = Directory(
      '${top.stdout.toString().trim()}/${pin['path']}',
    );
    if (directory.resolveSymbolicLinksSync() !=
        expectedDirectory.resolveSymbolicLinksSync()) {
      throw StateError(
        '$name resolved package directory differs from the pinned subdirectory',
      );
    }
    final changes = await Process.run('git', [
      '-C',
      top.stdout.toString().trim(),
      'status',
      '--porcelain',
      '--untracked-files=normal',
      '--',
      pin['path'] as String,
    ]);
    if (changes.exitCode != 0 || changes.stdout.toString().trim().isNotEmpty) {
      throw StateError(
        '$name resolved package contains modified or untracked source',
      );
    }
    final spec =
        loadYaml(File('${directory.path}/pubspec.yaml').readAsStringSync())
            as YamlMap;
    if (spec['name'] != name || spec['version'] != pin['version']) {
      throw StateError('$name package identity differs');
    }
    specs.add(spec);
  }
  for (final package in workspace['workspace'] as YamlList) {
    specs.add(
      loadYaml(File('${root.path}/$package/pubspec.yaml').readAsStringSync())
          as YamlMap,
    );
  }
  for (final spec in specs) {
    final deps = spec['dependencies'] as YamlMap? ?? YamlMap();
    for (final name in pins.keys) {
      if (!deps.containsKey(name)) continue;
      final constraint = deps[name];
      if (constraint is! String ||
          !VersionConstraint.parse(
            constraint,
          ).allows(Version.parse(pins[name]['version'] as String))) {
        throw StateError(
          '${spec['name']} declares incompatible $name constraint: $constraint',
        );
      }
    }
  }
  if (Directory('${root.path}/sound').existsSync() ||
      Directory('${root.path}/microphone').existsSync()) {
    throw StateError('Vendored audio trees must not return');
  }
  print(
    'Verified ${pins.length} immutable private dependency revisions, identities and original version constraints; no vendored trees.',
  );
}
