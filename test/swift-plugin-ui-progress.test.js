import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const viewModelPath = path.join(
  repositoryDirectory, 'Sources', 'SettingsUI', 'SettingsViewModel.swift'
)
const pluginsViewPath = path.join(
  repositoryDirectory, 'Sources', 'SettingsUI', 'PluginsTabView.swift'
)

test('P02 settings exposes durable plugin phases and outcome distinctions', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')

  for (const phase of [
    'case preparing',
    'case changing(action:',
    'case verifying',
    'case restoring',
    'case completed',
    'case recoveryRequired',
  ]) {
    assert.match(viewModel, new RegExp(phase.replace(/[().:?]/g, '\\$&')))
  }
  for (const outcome of [
    'case succeeded',
    'case restored',
    'case recoveryRequired',
    'case externalModification',
  ]) {
    assert.match(viewModel, new RegExp(outcome))
  }

  assert.match(viewModel, /DshPluginOperationCoordinator\.shared\.pendingOperation/)
  assert.match(viewModel, /beginPluginOperationProgress\(action:/)
  assert.match(viewModel, /finishPluginOperationFailed\(actionDescription:/)
  assert.match(viewModel, /Task\.sleep\(nanoseconds: 2_500_000_000\)/)
  assert.match(viewModel, /if operation\.phase == \.committed \{\s*\/\/[\s\S]*?schedulePluginOperationSuccessDismissal\(\)/)
  assert.match(viewModel, /pluginOperationDisplayGeneration == generation/)
  assert.match(viewModel, /pluginOperationOutcome == \.succeeded/)
  assert.match(viewModel, /pluginOperationDismissTask\?\.cancel\(\)/)
  assert.match(viewModel, /finalizeCommittedOperation\(operationID: result\.operationID\)/)
  assert.match(viewModel, /hasPersistedOperationRecord/)
  assert.match(pluginsView, /viewModel\.pluginOperationPhase/)
  assert.match(pluginsView, /ProgressView\(\)/)
  assert.match(pluginsView, /viewModel\.isOperatingPlugin \|\| !viewModel\.pluginMutationsAllowed/)

  // Read-only update inspection remains available while a mutation is active;
  // only the mutation buttons are gated by the operation lock.
  const inspectionButton = pluginsView.slice(
    pluginsView.indexOf('Text(viewModel.isCheckingPluginUpdates ?'),
    pluginsView.indexOf('Text(viewModel.isInspectingPlugins ?')
  )
  assert.doesNotMatch(inspectionButton, /isOperatingPlugin/)
})

test('P02 plugin list keeps four categories and a read-only search/exception filter', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')

  for (const category of ['受管理', '本地', '普通', '异常']) {
    assert.match(viewModel, new RegExp(`case \\w+ = "${category}"`))
  }
  assert.match(viewModel, /pluginSearchText/)
  assert.match(viewModel, /pluginExceptionsOnly/)
  assert.match(viewModel, /filteredInstalledPlugins/)
  assert.match(viewModel, /localizedCaseInsensitiveContains/)
  assert.match(viewModel, /func plugins\(in category: DshPluginListCategory\)/)
  assert.match(viewModel, /case \.missingPackage, \.notComposed, \.patchReferenceMissing/)
  assert.match(pluginsView, /搜索插件名称、版本或描述/)
  assert.match(pluginsView, /仅异常/)
  assert.match(pluginsView, /DshPluginListCategory\.allCases/)
})

test('P02 retry is fail-closed and never opts out of release-age policy', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')

  assert.match(viewModel, /canRetryPluginOperation/)
  assert.match(viewModel, /pluginOperationOutcome == \.restored/)
  assert.match(viewModel, /case \.absent = DshPluginOperationCoordinator\.shared\.persistedStatus/)
  assert.match(viewModel, /func retryLastPluginOperation\(\)/)
  assert.match(viewModel, /startPluginInstall\(spec: spec, ignoringMinimumReleaseAge: false\)/)
  assert.match(viewModel, /startPluginUpdate\(name: name, ignoringMinimumReleaseAge: false\)/)
  assert.match(viewModel, /startPluginUpdateAll\(ignoringMinimumReleaseAge: false\)/)
  assert.match(viewModel, /startPluginRemove\(name: name\)/)
  assert.match(viewModel, /DshPluginManager\.isMinimumReleaseAgeViolation\(error\)/)
  assert.match(viewModel, /preflightPluginUpdate\(/)
  assert.match(viewModel, /preflightAllPluginUpdates\(/)
  assert.match(viewModel, /finishPluginUpdatePreflight\(/)
  assert.match(pluginsView, /安全重试/)
  assert.match(pluginsView, /viewModel\.canRetryPluginOperation/)
})
