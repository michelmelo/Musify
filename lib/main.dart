import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:musify/API/musify.dart';
import 'package:musify/extensions/audio_quality.dart';
import 'package:musify/screens/root_page.dart';
import 'package:musify/services/audio_service.dart';
import 'package:musify/services/data_manager.dart';
import 'package:musify/services/logger_service.dart';
import 'package:musify/services/settings_manager.dart';
import 'package:musify/style/app_themes.dart';
import 'package:musify/utilities/formatter.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

late MusifyAudioHandler audioHandler;
final logger = Logger();

Locale locale = const Locale('en', '');
var isFdroidBuild = false;

final appLanguages = <String, String>{
  'English': 'en',
  'Arabic': 'ar',
  'French': 'fr',
  'Georgian': 'ka',
  'German': 'de',
  'Greek': 'el',
  'Polish': 'pl',
  'Portuguese': 'pt',
  'Spanish': 'es',
  'Turkish': 'tr',
  'Ukrainian': 'uk',
  'Vietnamese': 'vi',
};

final appSupportedLocales = appLanguages.values
    .map((languageCode) => Locale.fromSubtags(languageCode: languageCode))
    .toList();

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  static Future<void> updateAppState(
    BuildContext context, {
    ThemeMode? newThemeMode,
    Locale? newLocale,
    Color? newAccentColor,
    bool? useSystemColor,
  }) async {
    final state = context.findAncestorStateOfType<_MyAppState>()!;
    if (newThemeMode != null) {
      state.changeTheme(newThemeMode);
    }
    if (newLocale != null) {
      state.changeLanguage(newLocale);
    }
    if (newAccentColor != null && useSystemColor != null) {
      state.changeAccentColor(newAccentColor, useSystemColor);
    }
  }

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  void changeTheme(ThemeMode newThemeMode) {
    setState(() {
      themeMode = newThemeMode;
      brightness = getBrightnessFromThemeMode(newThemeMode);
      colorScheme = ColorScheme.fromSeed(
        seedColor: primaryColor,
        primary: primaryColor,
        brightness: brightness,
      ).harmonized();
    });
  }

  void changeLanguage(Locale newLocale) {
    setState(() {
      locale = newLocale;
    });
  }

  void changeAccentColor(Color newAccentColor, bool systemColorStatus) {
    setState(() {
      if (useSystemColor.value != systemColorStatus) {
        useSystemColor.value = systemColorStatus;

        addOrUpdateData(
          'settings',
          'useSystemColor',
          systemColorStatus,
        );
      }

      primaryColor = newAccentColor;

      colorScheme = ColorScheme.fromSeed(
        seedColor: newAccentColor,
        primary: newAccentColor,
        brightness: brightness,
      ).harmonized();
    });
  }

  @override
  void initState() {
    super.initState();
    final settingsBox = Hive.box('settings');
    final language =
        settingsBox.get('language', defaultValue: 'English') as String;
    locale = Locale(appLanguages[language] ?? 'en');
    final themeModeSetting = settingsBox.get('themeMode') as String?;

    if (themeModeSetting != null && themeModeSetting != themeMode.name) {
      themeMode = getThemeMode(themeModeSetting);
      brightness = getBrightnessFromThemeMode(themeMode);
    }

    GoogleFonts.config.allowRuntimeFetching = false;

    ReceiveSharingIntent.getTextStream().listen(
      (String? value) async {
        if (value == null) return;

        final regex = RegExp(r'(youtube\.com|youtu\.be)');
        if (!regex.hasMatch(value)) return;

        final songId = getSongId(value);
        if (songId == null) return;

        try {
          final song = await getSongDetails(0, songId);

          await audioHandler.playSong(song);
        } catch (e) {
          logger.log('Error while playing shared song: $e');
        }
      },
      onError: (err) {
        logger.log('getLinkStream error: $err');
      },
    );

    try {
      LicenseRegistry.addLicense(() async* {
        final license =
            await rootBundle.loadString('assets/fonts/roboto/LICENSE.txt');
        yield LicenseEntryWithLineBreaks(['google_fonts'], license);
        final license1 =
            await rootBundle.loadString('assets/fonts/paytone/OFL.txt');
        yield LicenseEntryWithLineBreaks(['google_fonts'], license1);
      });
    } catch (e) {
      logger.log('License Registration Error: $e');
    }
  }

  @override
  void dispose() {
    Hive.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightColorScheme, darkColorScheme) {
        if (lightColorScheme != null &&
            darkColorScheme != null &&
            useSystemColor.value) {
          colorScheme = brightness == Brightness.light
              ? lightColorScheme
              : darkColorScheme;
        }
        final lightTheme = getAppLightTheme();

        final darkTheme = getAppDarkTheme();

        return MaterialApp(
          themeMode: themeMode,
          darkTheme: darkTheme,
          theme: lightTheme,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: appSupportedLocales,
          locale: locale,
          home: Musify(),
        );
      },
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initialisation();
  runApp(const MyApp());
}

Future<void> initialisation() async {
  try {
    await setDisplayMode();
    await Hive.initFlutter();
    Hive.registerAdapter(AudioQualityAdapter());
    await Hive.openBox('settings');
    await Hive.openBox('user');
    await Hive.openBox('cache');

    audioHandler = await AudioService.init(
      builder: MusifyAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.gokadzev.musify',
        androidNotificationChannelName: 'Musify',
        androidNotificationIcon: 'drawable/ic_launcher_foreground',
        androidShowNotificationBadge: true,
      ),
    );

    FileDownloader().configureNotification(
      running: const TaskNotification('Downloading', 'file: {filename}'),
      complete: const TaskNotification('Download finished', 'file: {filename}'),
      progressBar: true,
    );
  } catch (e) {
    logger.log('Initialization Error: $e');
  }
}

Future<void> setDisplayMode() async {
  final supportedDisplay = await FlutterDisplayMode.supported;
  final activeDisplay = await FlutterDisplayMode.active;
  final sameResolution = supportedDisplay
      .where(
        (DisplayMode m) =>
            m.width == activeDisplay.width && m.height == activeDisplay.height,
      )
      .toList()
    ..sort(
      (DisplayMode a, DisplayMode b) => b.refreshRate.compareTo(a.refreshRate),
    );
  final mostOptimalMode =
      sameResolution.isNotEmpty ? sameResolution.first : activeDisplay;
  await FlutterDisplayMode.setPreferredMode(mostOptimalMode);
}
