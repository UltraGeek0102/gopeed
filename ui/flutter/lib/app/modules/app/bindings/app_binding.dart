import 'package:get/get.dart';

import '../controllers/app_controller.dart';
import '../../../../core/ios_background_download_lifecycle.dart';

class AppBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(IosDownloadProgressBus());
    Get.lazyPut<AppController>(
      () => AppController(),
    );
  }
}
