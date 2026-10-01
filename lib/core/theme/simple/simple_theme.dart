import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

class SimpleTheme {
  SimpleTheme._();
  static final ThemeData lightTheme =
      ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.light);
  static final ThemeData darkTheme =
      ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark);
}
