const String pluginName = 'Serverpod';

// commands
const String cmdServerpodStart = 'serverpod.start';
const String cmdServerpodStop = 'serverpod.stop';
const String cmdServerpodGenerate = 'serverpod.generate';
const String cmdServerpodCreateMigration = 'serverpod.createMigration';
const String cmdServerpodCreateRepairMigration =
    'serverpod.createRepairMigration';
const String cmdServerpodApplyMigrations = 'serverpod.applyMigrations';
const String cmdServerpodRunScript = 'serverpod.runScript';
const String cmdServerpodDockerUp = 'serverpod.docker.up';
const String cmdServerpodDockerStop = 'serverpod.docker.stop';
const String cmdServerpodCreate = 'serverpod.create';
const String cmdServerpodUpgrade = 'serverpod.upgrade';
const String cmdServerpodTools = 'serverpod.tools';

const String launchProviderServerpod = 'serverpod';
const String languageServerServerpod = 'serverpod';

// configuration
const String confGenerateOnSave = 'serverpod.generateOnSave';
const String confRunMode = 'serverpod.runMode';
const String confApplyMigrationsOnStart = 'serverpod.applyMigrationsOnStart';
const String confLaunchFlutterApps = 'serverpod.launchFlutterApps';
const String confLanguageServer = 'serverpod.languageServer';

// defaults
const bool defaultGenerateOnSave = true;
const String defaultRunMode = 'development';
const bool defaultApplyMigrationsOnStart = false;
const bool defaultLaunchFlutterApps = false;
const bool defaultLanguageServer = true;

const List<String> runModes = ['development', 'staging', 'production'];
const List<String> modelFileExtensions = ['.spy.yaml', '.spy.yml', '.spy'];

// executables
const String executableServerpod = 'serverpod';
const String executableDart = 'dart';
const String executableDocker = 'docker';

// output channels
const String channelServerpod = 'Serverpod';
const String channelServerpodServer = 'Serverpod Server';

// icons
const String iconPlay = 'play';
const String iconStop = 'stop';
const String iconCode = 'code';
const String iconDatabase = 'database';
const String iconDatabaseZap = 'database-zap';
const String iconWrench = 'wrench';
const String iconTerminal = 'terminal';
const String iconContainer = 'container';
const String iconFolderPlus = 'folder-plus';
const String iconUpgrade = 'circle-arrow-up';
const String iconServer = 'server';

// assets
const String assetIconServerpod = 'assets/icon_serverpod.svg';
const String assetIconServerpodSolid = 'assets/icon_serverpod_solid.svg';
