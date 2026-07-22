import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vplayer/app.dart';

void main() {
  group('isTabletDimensions', () {
    test('iPad-class screens are tablets', () {
      expect(isTabletDimensions(const Size(768, 1024)), true); // iPad
      expect(isTabletDimensions(const Size(1024, 768)), true); // landscape
      expect(isTabletDimensions(const Size(834, 1194)), true); // iPad Pro 11
    });

    test('Android tablets at the 600dp threshold are tablets', () {
      expect(isTabletDimensions(const Size(600, 960)), true);
      expect(isTabletDimensions(const Size(960, 600)), true);
    });

    test('phones are not tablets', () {
      expect(isTabletDimensions(const Size(411, 914)), false); // Pixel
      expect(isTabletDimensions(const Size(390, 844)), false); // iPhone
      expect(isTabletDimensions(const Size(914, 411)), false); // landscape
      expect(isTabletDimensions(const Size(599, 960)), false); // just under
    });
  });

  group('appOrientations', () {
    test('tablets are landscape-first', () {
      expect(appOrientations(true), const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    });

    test('phones are portrait', () {
      expect(appOrientations(false), const [DeviceOrientation.portraitUp]);
    });
  });
}
