# RaceBox Mini S over Bluetooth (Delphi)

Reads a RaceBox Mini, Mini S or Micro from a Windows PC over Bluetooth LE:
live GPS/motion data at 25 Hz, and the sessions recorded on the device
(standalone recording, Mini S and Micro only). Downloaded sessions can be
saved as CSV. This is the data-capture step for later lap and track-map work,
so every reading ends up in one plain record, `TRaceBoxSample`.

It uses Delphi's own `System.Bluetooth` classes (RAD Studio 12, Windows 10 or
later). No third-party libraries.

## Folder layout

| Path | What it is |
|---|---|
| `Source/RaceBox.Protocol.pas` | Packet framing, checksum, commands and decoders. No Bluetooth, also builds with Free Pascal. |
| `Source/RaceBox.Session.pas` | Splits a download into sessions, CSV save/load, decodes a saved raw download. No Bluetooth. |
| `Source/RaceBox.Import.pas` | Reads sessions exported from the RaceBox app/website (CSV, VBO, GPX). No Bluetooth. |
| `Source/RaceBox.BLE.pas` | `TRaceBoxClient`: scan, connect, live data, unlock, download, erase. Delphi only. |
| `Demo/RaceBoxReader.dpr` | Small VCL app that uses all of the above. |
| `Tests/RaceBoxProtocolTest.dpr`, `Tests/RaceBoxImportTest.dpr` | Console tests. |

## Using the demo

1. Open `Demo/RaceBoxReader.dpr` in RAD Studio 12 (it creates the `.dproj`), build for Win32 or Win64 and run.
2. Switch the RaceBox on. **Close the RaceBox phone app** or turn off the phone's Bluetooth: the device takes one connection at a time.
3. Press **Scan**, pick the RaceBox in the list, press **Connect**. The status bar counts the seconds while it
   connects (the first connect can take 10-20 s); **Cancel** stops it, and it gives up by itself after 30 s.
   Live data shows on the left once connected.
4. If you set a memory security code in the RaceBox app, type it and press **Unlock** (needed after every connect).
5. **Status** shows how many records are stored. **Download** fetches all of them; a full memory (196,608 records) takes a few minutes.
6. Select sessions in the list (or none for all) and press **Save CSV...** to write one file per session.
   **Save raw...** keeps the exact bytes received; **Open file...** decodes a raw file or a CSV again without the device.

The RaceBox does not need to be paired in Windows settings first.

## Sessions recorded with the RaceBox phone app

Sessions recorded through the phone app are stored on the phone and in your
RaceBox account, not on the device, so a Bluetooth download won't find them.
Export them instead:

1. Log in at racebox.pro and open **My Sessions** (sessions with no laps or
   runs are hidden; the link at the bottom of the list shows them).
2. Open a session, press the export button, and pick **CSV** (or VBO / GPX).
   For CSV, include at least Time, Latitude, Longitude and Speed; add the
   GForce, Gyro and Lap columns if they are offered.
3. In the demo, press **Open file...** and pick one or more exported files.
   Each file becomes a session; **Save CSV...** writes it in this project's
   CSV format, so app sessions and Bluetooth downloads end up identical.

In code: `Session := RaceBoxImportFile('export.csv', Info);`. `Info` says which
columns were recognised, the speed unit and how the time was read.

- **CSV:** columns are matched by name (RaceBox lets you choose them), and units are
  read from names such as `Speed (mph)`. A speed column without a unit is taken as km/h;
  change that with `TRaceBoxImportOptions.SpeedUnit`. Decimal commas aren't supported.
- **VBO:** standard VBOX layout (positions in minutes, longitude positive west).
- **GPX:** position and time only; speed and heading are worked out from the track.

## Using it in your own code

```pascal
uses RaceBox.Protocol, RaceBox.Session, RaceBox.BLE;

FClient := TRaceBoxClient.Create;
FClient.OnDeviceFound := DeviceFound;      // (Index, Name, Address, Rssi)
FClient.OnConnected := Connected;
FClient.OnLiveSample := LiveSample;        // TRaceBoxSample, 25 Hz
FClient.OnDownloadComplete := DownloadDone;
FClient.StartScan;
...
FClient.Connect(Index);                    // returns at once, connects in the background
FClient.Unlock(123456);                    // only if security is on
FClient.StartDownload;
...
procedure TForm1.DownloadDone(Sender: TObject; Cancelled: Boolean);
var Sessions: TRaceBoxSessionList;
begin
  Sessions := FClient.ExtractSessions;     // you own it now
  RaceBoxSaveSessionsCsv('C:\RaceBox', Sessions);
  ...
end;
```

Events run on the main thread, so you can touch the UI in them. `OnStateChanged` fires
whenever `State` changes (scanning, connecting, connected...), which is the place to show a busy cursor.
`ConnectTimeoutMs` (default 30000) sets how long a connect may take.

### `TRaceBoxSample`

| Field | Unit |
|---|---|
| `UtcTime`, `UnixTimeMs`, `TimeValid` | UTC `TDateTime`, ms since 1970 |
| `Latitude`, `Longitude` | degrees |
| `AltitudeMSL`, `AltitudeWGS` | m |
| `Speed` / `SpeedKmh` | m/s / km/h |
| `Heading` | degrees, 0 = north |
| `GForceX` / `Y` / `Z` | g (X front/back, Y right/left, Z up/down) |
| `GyroX` / `Y` / `Z` | deg/s (roll, pitch, yaw) |
| `FixStatus`, `NumSV`, `PDOP`, `HorizAccuracy` ... | fix quality |
| `HasGoodFix` | 3D fix with the valid-fix flag set; ignore positions when False |

### Sessions

The device stores everything in one memory. It writes a state-change record
when recording starts, stops, or pauses, so a new session starts at each
recording start. As a fallback, a gap of more than `MaxGapSeconds` (default
300 s) between samples also starts a new session; set it to 0 to turn that off.

### CSV columns

`utc_time, unix_ms, itow_ms, latitude, longitude, alt_msl_m, alt_wgs_m,
speed_kmh, speed_ms, heading_deg, fix, fix_ok, sats, pdop, h_acc_m, v_acc_m,
speed_acc_ms, heading_acc_deg, g_x, g_y, g_z, gyro_x_dps, gyro_y_dps,
gyro_z_dps, battery_raw, fix_flags, latlon_flags`

Decimal point is always `.`, times are UTC. `unix_ms` is the easiest column
for lining the data up with other logs (for example VCDS CSV files).

## Tests

```
cd Tests
dcc32 -U..\Source RaceBoxProtocolTest.dpr && RaceBoxProtocolTest
```
or with Free Pascal: `fpc -Mdelphi -Fu../Source RaceBoxProtocolTest.dpr`.
`Tests\RunTests.bat` runs the tests and also builds the demo, which compiles
`RaceBox.BLE` (it finds RAD Studio by itself, or set `BDS`).
GitHub Actions runs the Free Pascal tests on every push (`.github/workflows/tests.yml`).

`RaceBoxImportTest` checks the CSV, VBO and GPX import on small hand-made files.
The protocol tests check every example packet in the RaceBox protocol document, the stream
parser (split and merged notifications, garbage, bad checksums), sample
decoding, session splitting and the CSV round trip.

## What has and has not been tested

- `RaceBox.Protocol` and `RaceBox.Session`: tests pass under Free Pascal 3.2 and under Delphi (dcc32 37.0).
- `RaceBox.BLE` and the demo compile cleanly with dcc32, but have **not been run against a real RaceBox yet**.
  If the scan finds nothing or connecting fails, the log at the bottom of the demo window shows which step stopped.
- Stopping/starting recording and erasing memory are in `TRaceBoxClient` but not in the demo,
  because erasing cannot be undone.

## Licence

zlib, see `LICENSE`.

## Protocol source

[RaceBox BLE Protocol Documentation, revision 9](https://www.racebox.pro/products/mini-micro-protocol-documentation).
Recorded-data download needs firmware that supports standalone recording (Mini S / Micro).
