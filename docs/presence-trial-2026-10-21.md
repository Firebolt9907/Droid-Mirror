# First Bluetooth presence trial

User reported #1 fired five times: one true positive and four false positives
(20% precision among observed alerts). Recall is unknown: no count of missed
actual departures was supplied. Preserve #1 as the baseline for comparison.

#2–#4 each reported 123 unavailable probes and no alerts. These are not successful
negative detections and do not establish lower false-positive rates. The three
channels had no usable exposure in this trial.

Read-only inspection of the connected Pixel 8 found the counters had reached 124
unavailable probes per channel. All three latest statuses were `Nearby devices
permission required`. Android granted BLUETOOTH_CONNECT and POST_NOTIFICATIONS,
but BLUETOOTH_SCAN was denied.

The old shared SCAN-or-CONNECT guard disabled all three sampled paths, including
Classic which did not need BLE scanning. The repair separates the scan gate from
Classic, shows individual permission status, automatically requests missing
permissions on reopening an enabled experiment, and refreshes results while open.
Existing counters and pairing data are preserved. Results after the fix should
be assessed only once the intended channels have recorded nearby successes.

The direct permission grant was rejected by automatic approval review. No device
permission was changed and no APK was installed during diagnosis.
