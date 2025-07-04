// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/assist.dart';
import 'package:analyzer_plugin/utilities/assist/assist.dart';
import 'package:linter/src/lint_names.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'assist_processor.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(FlutterWrapBuilderTest);
  });
}

@reflectiveTest
class FlutterWrapBuilderTest extends AssistProcessorTest {
  @override
  AssistKind get kind => DartAssistKind.flutterWrapBuilder;

  @override
  void setUp() {
    super.setUp();
    writeTestPackageConfig(flutter: true);
  }

  Future<void> test_aroundBuilder() async {
    await resolveTestCode('''
import 'package:flutter/widgets.dart';

void f() {
  ^Builder(
    builder: (context) => Text(''),
  );
}
''');
    await assertNoAssist();
  }

  Future<void> test_aroundNamedConstructor() async {
    await resolveTestCode('''
import 'package:flutter/widgets.dart';

class MyWidget extends StatelessWidget {
  MyWidget.named();

  Widget build(BuildContext context) => Text('');
}

Widget f() {
  return MyWidget.^named();
}
''');
    await assertHasAssist('''
import 'package:flutter/widgets.dart';

class MyWidget extends StatelessWidget {
  MyWidget.named();

  Widget build(BuildContext context) => Text('');
}

Widget f() {
  return Builder(
    builder: (context) {
      return MyWidget.named();
    }
  );
}
''');
  }

  Future<void> test_aroundText() async {
    await resolveTestCode('''
import 'package:flutter/widgets.dart';

void f() {
  ^Text('a');
}
''');
    await assertHasAssist('''
import 'package:flutter/widgets.dart';

void f() {
  Builder(
    builder: (context) {
      return Text('a');
    }
  );
}
''');
  }

  Future<void> test_assignment() async {
    await resolveTestCode('''
import 'package:flutter/widgets.dart';

void f() {
  Widget w;
  w = ^Container();
}
''');
    await assertHasAssist('''
import 'package:flutter/widgets.dart';

void f() {
  Widget w;
  w = Builder(
    builder: (context) {
      return Container();
    }
  );
}
''');
  }

  Future<void> test_expressionFunctionBody() async {
    await resolveTestCode('''
import 'package:flutter/widgets.dart';
class FakeFlutter {
  void f() => ^Container();
}
''');
    await assertHasAssist('''
import 'package:flutter/widgets.dart';
class FakeFlutter {
  void f() => Builder(
    builder: (context) {
      return Container();
    }
  );
}
''');
  }

  Future<void> test_trailingComma_disabled() async {
    // No analysis options.
    await resolveTestCode('''
import 'package:flutter/widgets.dart';

class TestWidget extends StatelessWidget {
  const TestWidget({super.key});
  @override
  Widget build(BuildContext context) {
    return const ^Text('hi');
  }
}
''');
    await assertHasAssist('''
import 'package:flutter/widgets.dart';

class TestWidget extends StatelessWidget {
  const TestWidget({super.key});
  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        return const Text('hi');
      }
    );
  }
}
''');
  }

  Future<void> test_trailingComma_enabled() async {
    createAnalysisOptionsFile(lints: [LintNames.require_trailing_commas]);
    await resolveTestCode('''
import 'package:flutter/widgets.dart';

class TestWidget extends StatelessWidget {
  const TestWidget({super.key});
  @override
  Widget build(BuildContext context) {
    return const ^Text('hi');
  }
}
''');
    await assertHasAssist('''
import 'package:flutter/widgets.dart';

class TestWidget extends StatelessWidget {
  const TestWidget({super.key});
  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        return const Text('hi');
      },
    );
  }
}
''');
  }

  Future<void> test_variableDeclaration() async {
    await resolveTestCode('''
import 'package:flutter/widgets.dart';

void f() {
  Widget w = ^Container();
}
''');
    await assertHasAssist('''
import 'package:flutter/widgets.dart';

void f() {
  Widget w = Builder(
    builder: (context) {
      return Container();
    }
  );
}
''');
  }
}
