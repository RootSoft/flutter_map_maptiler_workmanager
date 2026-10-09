## [0.1.0-dev.1] - Initial Release

* Background downloads of MapTiler offline packs with workmanager, through
  `MapTilerWorkmanagerScheduler`
* Android: one-off tasks with constraints, exponential backoff, and optional
  foreground service
* iOS: continued processing tasks (iOS 26+), falling back to processing tasks
* `MapTilerWorkmanager` entry points for the background isolate, usable from a
  custom callback dispatcher
