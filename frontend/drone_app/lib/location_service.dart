export 'location_stub.dart'
    if (dart.library.html) 'location_web.dart'
    if (dart.library.io) 'location_native.dart';
