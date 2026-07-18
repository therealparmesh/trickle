import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';

abstract final class TrickleFonts {
  static const ui = 'SpaceGrotesk';
  static const display = 'ChakraPetch';
}

abstract final class TrickleTheme {
  static const _tabLabelStyle = TextStyle(
    fontFamily: TrickleFonts.display,
    fontSize: 14,
    height: 1.1,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.55,
  );

  static final ThemeData dark = _buildDark();

  static ThemeData _buildDark() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppConstants.cyan,
          brightness: Brightness.dark,
          surface: AppConstants.surface,
          error: AppConstants.danger,
        ).copyWith(
          primary: AppConstants.cyan,
          secondary: AppConstants.magenta,
          tertiary: AppConstants.acid,
          surface: AppConstants.surface,
          onSurface: AppConstants.primaryText,
          onPrimary: AppConstants.background,
          onSecondary: AppConstants.background,
          onTertiary: AppConstants.background,
          outline: AppConstants.secondaryText.withValues(alpha: 0.34),
        );
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppConstants.background,
      visualDensity: VisualDensity.standard,
      fontFamily: TrickleFonts.ui,
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppConstants.background,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: AppConstants.primaryText,
          fontFamily: TrickleFonts.display,
          fontSize: 23,
          height: 1.05,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      textTheme: base.textTheme
          .apply(
            bodyColor: AppConstants.primaryText,
            displayColor: AppConstants.primaryText,
          )
          .copyWith(
            displaySmall: const TextStyle(
              fontFamily: TrickleFonts.display,
              fontSize: 38,
              height: 1.02,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.45,
            ),
            headlineMedium: const TextStyle(
              fontFamily: TrickleFonts.display,
              fontSize: 27,
              height: 1.08,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
            titleLarge: const TextStyle(
              fontFamily: TrickleFonts.display,
              fontSize: 21,
              height: 1.12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.15,
            ),
            titleMedium: const TextStyle(
              fontSize: 16,
              height: 1.25,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
            titleSmall: const TextStyle(
              fontSize: 14,
              height: 1.22,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
            bodyLarge: const TextStyle(
              fontSize: 16,
              height: 1.5,
              fontWeight: FontWeight.w400,
              letterSpacing: -0.1,
            ),
            bodyMedium: const TextStyle(
              fontSize: 14,
              height: 1.45,
              fontWeight: FontWeight.w400,
              letterSpacing: 0,
            ),
            bodySmall: const TextStyle(
              fontSize: 12,
              height: 1.35,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.08,
            ),
            labelLarge: const TextStyle(
              fontFamily: TrickleFonts.display,
              fontSize: 14,
              height: 1.1,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.25,
            ),
            labelMedium: const TextStyle(
              fontFamily: TrickleFonts.display,
              fontSize: 12,
              height: 1.1,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
            labelSmall: const TextStyle(
              fontFamily: TrickleFonts.display,
              fontSize: 10,
              height: 1.1,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.75,
            ),
          ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppConstants.elevated,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppConstants.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppConstants.cyan),
        ),
        labelStyle: const TextStyle(color: AppConstants.secondaryText),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: AppConstants.surface,
        selectedColor: AppConstants.cyan.withValues(alpha: 0.12),
        side: const BorderSide(color: AppConstants.hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppConstants.cyan.withValues(alpha: 0.12)
                : AppConstants.surface,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppConstants.cyan
                : AppConstants.secondaryText,
          ),
          side: const WidgetStatePropertyAll(
            BorderSide(color: AppConstants.hairline),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: TrickleFonts.display,
              fontSize: 13,
              height: 1.1,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.45,
            ),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          visualDensity: VisualDensity.standard,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: AppConstants.background,
          backgroundColor: AppConstants.cyan,
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontFamily: TrickleFonts.display,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.25,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size.square(48)),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return AppConstants.secondaryText.withValues(alpha: 0.45);
          }
          return states.contains(WidgetState.selected)
              ? AppConstants.background
              : AppConstants.primaryText;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return AppConstants.hairline.withValues(alpha: 0.55);
          }
          return states.contains(WidgetState.selected)
              ? AppConstants.cyan
              : AppConstants.elevated;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? AppConstants.cyan
              : AppConstants.hairline;
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppConstants.elevated,
        contentTextStyle: const TextStyle(
          color: AppConstants.primaryText,
          fontFamily: TrickleFonts.ui,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: const DividerThemeData(
        color: AppConstants.hairline,
        thickness: 0.7,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppConstants.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppConstants.hairline),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppConstants.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: AppConstants.hairline,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppConstants.elevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppConstants.hairline),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppConstants.cyan,
        linearTrackColor: AppConstants.hairline,
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: const WidgetStatePropertyAll(AppConstants.surface),
        side: const WidgetStatePropertyAll(
          BorderSide(color: AppConstants.hairline),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        hintStyle: const WidgetStatePropertyAll(
          TextStyle(color: AppConstants.secondaryText),
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: AppConstants.cyan,
        labelColor: AppConstants.cyan,
        unselectedLabelColor: AppConstants.secondaryText,
        dividerColor: AppConstants.hairline,
        labelStyle: _tabLabelStyle,
        unselectedLabelStyle: _tabLabelStyle,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppConstants.secondaryText,
        textColor: AppConstants.primaryText,
        subtitleTextStyle: TextStyle(
          color: AppConstants.secondaryText,
          fontSize: 12,
        ),
      ),
    );
  }
}

final class AdaptiveAppChrome extends StatelessWidget {
  const AdaptiveAppChrome({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle =
        theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge;
    final scaledTitleHeight =
        MediaQuery.textScalerOf(context).scale(titleStyle?.fontSize ?? 22) *
        (titleStyle?.height ?? 1.2);
    final toolbarHeight = math.max(kToolbarHeight, scaledTitleHeight + 16);
    return Theme(
      data: theme.copyWith(
        appBarTheme: theme.appBarTheme.copyWith(toolbarHeight: toolbarHeight),
      ),
      child: child,
    );
  }
}
