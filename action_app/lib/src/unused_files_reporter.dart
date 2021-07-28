import 'dart:math';

import 'package:actions_toolkit_dart/core.dart';
import 'package:dart_code_metrics/unused_files_analyzer.dart';
import 'package:github/github.dart';

import 'arguments.dart';
import 'github_workflow_utils.dart';

const _checkRunName = 'Dart Code Metrics unused files report';
const _homePage = 'https://github.com/dart-code-checker/dart-code-metrics';

class UnusedFilesReporter {
  static Future<UnusedFilesReporter> create({
    required GitHubWorkflowUtils workflowUtils,
    required Arguments arguments,
  }) async {
    final client =
        GitHub(auth: Authentication.withToken(arguments.gitHubToken));
    final slug = RepositorySlug.full(arguments.repositorySlug);
    try {
      final id = '${Random().nextInt(1000)}';
      final name =
          workflowUtils.isTestMode() ? '$_checkRunName ($id)' : _checkRunName;

      debug(message: 'Id attributed to checkrun: $id');

      final checkRun = await client.checks.checkRuns.createCheckRun(
        slug,
        name: name.toString(),
        headSha: arguments.commitSha,
        status: CheckRunStatus.queued,
        detailsUrl: _homePage,
        externalId: id,
      );

      return UnusedFilesReporter._(client, workflowUtils, checkRun, slug);
    } on GitHubError catch (e) {
      if (e.toString().contains('Resource not accessible by integration')) {
        warning(
          message:
              "It seems that this action doesn't have the required permissions to call the GitHub API with the token you gave. "
              "This can occur if this repository is a fork, as in that case GitHub reduces the GITHUB_TOKEN's permissions for security reasons. "
              'Consequently, no report will be made on GitHub.',
        );

        return UnusedFilesReporter._(client, workflowUtils, null, slug);
      }
      rethrow;
    }
  }

  final GitHub _client;
  final GitHubWorkflowUtils _workflowUtils;
  final CheckRun? _checkRun;
  final RepositorySlug _repositorySlug;
  final DateTime _startTime;

  UnusedFilesReporter._(
    this._client,
    this._workflowUtils,
    this._checkRun,
    this._repositorySlug,
  ) : _startTime = DateTime.now();

  Future<void> run() async {
    if (_checkRun == null) {
      return;
    }

    await _client.checks.checkRuns.updateCheckRun(
      _repositorySlug,
      _checkRun!,
      startedAt: _startTime,
      status: CheckRunStatus.inProgress,
    );
  }

  Future<void> complete(
    String packageName,
    Iterable<String> scannedFolder,
    Iterable<UnusedFilesFileReport> report,
  ) async {
    if (_checkRun == null) {
      return;
    }

    final conclusion = report.isNotEmpty
        ? CheckRunConclusion.failure
        : CheckRunConclusion.success;

    final summary = StringBuffer();
    if (_workflowUtils.isTestMode()) {
      summary
        ..writeln('**THIS ACTION HAS BEEN EXECUTED IN TEST MODE.**')
        ..writeln('**Conclusion = `$conclusion`**');
    }

    summary.write(_generateSummary(scannedFolder, report));

    final checkRun = await _client.checks.checkRuns.updateCheckRun(
      _repositorySlug,
      _checkRun!,
      status: CheckRunStatus.completed,
      startedAt: _startTime,
      completedAt: DateTime.now(),
      conclusion:
          _workflowUtils.isTestMode() ? CheckRunConclusion.neutral : conclusion,
      output: CheckRunOutput(
        title: _generateTitle(packageName),
        summary: summary.toString(),
        text: _generateDetails(report),
      ),
    );

    info(message: 'Check Run Id: ${checkRun.id}');
    info(message: 'Check Suite Id: ${checkRun.checkSuiteId}');
    info(message: 'Report posted at: ${checkRun.detailsUrl}');
  }

  Future<void> cancel({required Exception cause}) async {
    if (_checkRun == null) {
      return;
    }

    debug(message: "Checkrun cancelled. Conclusion is 'CANCELLED'.");
    await _client.checks.checkRuns.updateCheckRun(
      _repositorySlug,
      _checkRun!,
      startedAt: _startTime,
      completedAt: DateTime.now(),
      status: CheckRunStatus.completed,
      conclusion: _workflowUtils.isTestMode()
          ? CheckRunConclusion.neutral
          : CheckRunConclusion.cancelled,
      output: CheckRunOutput(
        title: _checkRun?.name ?? '',
        summary:
            'This check run has been cancelled, due to the following error:'
            '\n\n```\n$cause\n```\n\n'
            'Check your logs for more information.',
      ),
    );
  }

  String _generateTitle(String packageName) =>
      'Unused files report result for $packageName';

  String _generateSummary(
    Iterable<String> scannedFolders,
    Iterable<UnusedFilesFileReport> report,
  ) {
    final buffer = StringBuffer()..writeln('## Summary')..writeln();
    if (scannedFolders.isNotEmpty) {
      buffer.writeln(
        scannedFolders.length == 1
            ? '* Scanned package folder: ${scannedFolders.single}'
            : '* Scanned package folders: ${scannedFolders.join(', ')}',
      );
    }

    buffer.writeln(report.isEmpty
        ? '* No unused files found! ✅'
        : '* Found unused files: ${report.length} ⚠');

    return buffer.toString();
  }

  String? _generateDetails(Iterable<UnusedFilesFileReport> report) {
    if (report.isEmpty) {
      return null;
    }

    final buffer = StringBuffer()..writeln('## Unused files:')..writeln();
    for (final file in report) {
      buffer.writeln('* ${file.relativePath}');
    }

    return buffer.toString();
  }
}
