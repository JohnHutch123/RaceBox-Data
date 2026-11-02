unit RaceBox.Protocol;

{ RaceBox Mini / Mini S / Micro binary protocol: packet framing, checksum,
  command builders and message decoders. No Bluetooth code here, so this unit
  also builds with Free Pascal and can be tested without a device.

  Source: "RaceBox BLE Protocol Documentation", revision 9
  (https://www.racebox.pro/products/mini-micro-protocol-documentation).

  Packet layout (all multi-byte values little-endian):
    B5 62 | class | id | length (U16) | payload | CK_A CK_B
  The checksum is the 8-bit Fletcher sum over class .. end of payload.

  RaceBox-Data, zlib licence (see LICENSE). }

{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$MINFPCONSTPREC 64}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes;
{$ENDIF}

const
  RB_SYNC1 = $B5;
  RB_SYNC2 = $62;
  RB_HEADER_SIZE = 6;        // sync1 sync2 class id lenLo lenHi
  RB_OVERHEAD = 8;           // header + 2 checksum bytes
  RB_MAX_PAYLOAD = 504;

  RB_CLASS = $FF;            // every RaceBox message uses class FF

  RB_ID_DATA         = $01;  // live data, 80 bytes
  RB_ID_ACK          = $02;  // payload: class, id of the acknowledged command
  RB_ID_NACK         = $03;
  RB_ID_HISTORY      = $21;  // recorded data, same 80-byte layout as RB_ID_DATA
  RB_ID_REC_STATUS   = $22;  // standalone recording status
  RB_ID_DOWNLOAD     = $23;  // recorded data download (start / cancel / reply)
  RB_ID_ERASE        = $24;  // erase memory (start / cancel / progress)
  RB_ID_REC_CONFIG   = $25;  // standalone recording configuration
  RB_ID_STATE_CHANGE = $26;  // standalone recording state change
  RB_ID_GNSS_CONFIG  = $27;  // GNSS receiver configuration (FW 3.3+)
  RB_ID_UNLOCK       = $30;  // unlock memory with security code

  RB_DATA_PAYLOAD_SIZE = 80;

  { Bluetooth LE UUIDs. The UART service is the Nordic UART Service. }
  RB_UUID_UART_SERVICE = '{6E400001-B5A3-F393-E0A9-E50E24DCCA9E}';
  RB_UUID_UART_RX      = '{6E400002-B5A3-F393-E0A9-E50E24DCCA9E}'; // we write here
  RB_UUID_UART_TX      = '{6E400003-B5A3-F393-E0A9-E50E24DCCA9E}'; // device notifies here
  RB_UUID_DEVINFO_SERVICE = '{0000180A-0000-1000-8000-00805F9B34FB}';
  RB_UUID_DEVINFO_MODEL   = '{00002A24-0000-1000-8000-00805F9B34FB}';
  RB_UUID_DEVINFO_SERIAL  = '{00002A25-0000-1000-8000-00805F9B34FB}';
  RB_UUID_DEVINFO_FIRMWARE = '{00002A26-0000-1000-8000-00805F9B34FB}';
  RB_UUID_DEVINFO_HARDWARE = '{00002A27-0000-1000-8000-00805F9B34FB}';
  RB_UUID_DEVINFO_MANUFACTURER = '{00002A29-0000-1000-8000-00805F9B34FB}';

  { Recording data rates (TRaceBoxRecordingConfig.DataRate) }
  RB_RATE_25HZ = 0;
  RB_RATE_10HZ = 1;
  RB_RATE_5HZ  = 2;
  RB_RATE_1HZ  = 3;
  RB_RATE_20HZ = 4;          // FW 3.3+

  { Recording feature flags }
  RB_REC_WAIT_FOR_FIX      = $01;
  RB_REC_STATIONARY_FILTER = $02;
  RB_REC_NOFIX_FILTER      = $04;
  RB_REC_AUTO_SHUTDOWN     = $08;
  RB_REC_WAIT_FOR_DATA     = $10;

  { Recording states (TRaceBoxStateChange.State) }
  RB_STATE_DISABLED = 0;
  RB_STATE_RUNNING  = 1;
  RB_STATE_PAUSED   = 2;

type
  TRaceBoxPacket = record
    MsgClass: Byte;
    MsgId: Byte;
    Payload: TBytes;
  end;

  TRaceBoxSampleSource = (rssLive, rssHistory);

  { One decoded RaceBox Data Message (live) or History Data Message (recorded),
    converted to SI-style units. This is the record the rest of the app uses. }
  TRaceBoxSample = record
    Source: TRaceBoxSampleSource;
    ITOW: Cardinal;              // ms since start of GPS week
    Year: Word;
    Month, Day, Hour, Minute, Second: Byte;
    Nanoseconds: Integer;        // signed fraction of the second, can be negative
    TimeValid: Boolean;          // date and time valid flags both set
    UtcTime: TDateTime;          // UTC; 0 when the date is not valid
    UnixTimeMs: Int64;           // ms since 1970-01-01 UTC; 0 when not valid
    ValidityFlags: Byte;
    TimeAccuracyNs: Cardinal;
    FixStatus: Byte;             // 0 none, 2 = 2D, 3 = 3D
    FixStatusFlags: Byte;
    DateTimeFlags: Byte;
    NumSV: Byte;                 // satellites used
    Longitude: Double;           // degrees
    Latitude: Double;            // degrees
    AltitudeWGS: Double;         // m above ellipsoid
    AltitudeMSL: Double;         // m above mean sea level
    HorizAccuracy: Double;       // m
    VertAccuracy: Double;        // m
    Speed: Double;               // m/s
    Heading: Double;             // degrees, 0 = north
    SpeedAccuracy: Double;       // m/s
    HeadingAccuracy: Double;     // degrees
    PDOP: Double;
    LatLonFlags: Byte;
    BatteryRaw: Byte;            // see BatteryPercent / IsCharging / InputVoltage
    GForceX: Double;             // g, front/back
    GForceY: Double;             // g, right/left
    GForceZ: Double;             // g, up/down
    GyroX: Double;               // deg/s, roll
    GyroY: Double;               // deg/s, pitch
    GyroZ: Double;               // deg/s, yaw
    Lap: Integer;                // lap number from an imported file; 0 if unknown
    function SpeedKmh: Double;
    function HasGoodFix: Boolean;      // 3D fix and "valid fix" flag
    function PositionValid: Boolean;   // lat/lon not flagged invalid and fix present
    function HeadingValid: Boolean;
    function BatteryPercent: Integer;  // Mini / Mini S
    function IsCharging: Boolean;      // Mini / Mini S
    function InputVoltage: Double;     // Micro only
  end;

  TRaceBoxRecordingStatus = record
    Recording: Boolean;
    MemoryLevel: Byte;           // 0..100 %
    SecurityEnabled: Boolean;
    Unlocked: Boolean;
    StoredMessages: Cardinal;
    MemorySize: Cardinal;        // capacity, in data messages
  end;

  TRaceBoxRecordingConfig = record
    Enable: Boolean;
    DataRate: Byte;              // RB_RATE_*
    Flags: Byte;                 // RB_REC_*
    StationarySpeedMmS: Word;    // stationary filter speed threshold, mm/s
    StationaryIntervalS: Word;
    NoFixIntervalS: Word;
    AutoShutdownIntervalS: Word;
    class function Default: TRaceBoxRecordingConfig; static;
  end;

  TRaceBoxStateChange = record
    State: Byte;                 // RB_STATE_*
    DataRate: Byte;
    Flags: Byte;
    StationarySpeedMmS: Word;
    StationaryIntervalS: Word;
    NoFixIntervalS: Word;
    AutoShutdownIntervalS: Word;
  end;

  TRaceBoxGnssConfig = record
    PlatformModel: Byte;         // 4 automotive, 5 sea, 6 airborne <1g, 8 airborne <4g
    Speed3D: Boolean;            // report 3D speed instead of ground speed
    MinHorizAccuracyM: Byte;
  end;

  { Collects bytes from BLE notifications (which can hold part of a packet,
    several packets, or both) and returns complete, checksum-verified packets. }
  TRaceBoxPacketParser = class
  private
    FBuf: TBytes;
    FCount: Integer;
    FChecksumErrors: Int64;
    FBytesDiscarded: Int64;
    FPackets: Int64;
    procedure Discard(N: Integer);
  public
    procedure Feed(const Data: TBytes); overload;
    procedure Feed(Data: PByte; Count: Integer); overload;
    { Returns True and the next packet when one is complete. Call in a loop. }
    function Next(out Packet: TRaceBoxPacket): Boolean;
    procedure Reset;
    property BufferedBytes: Integer read FCount;
    property ChecksumErrors: Int64 read FChecksumErrors;
    property BytesDiscarded: Int64 read FBytesDiscarded;
    property PacketCount: Int64 read FPackets;
  end;

{ Framing }
procedure RaceBoxChecksum(const Data: TBytes; Start, Count: Integer; out CkA, CkB: Byte);
function RaceBoxBuildPacket(MsgClass, MsgId: Byte; const Payload: array of Byte): TBytes;

{ Commands (complete packets, ready to write to the UART RX characteristic) }
function RaceBoxCmdRecordingStatus: TBytes;
function RaceBoxCmdStartDownload: TBytes;
function RaceBoxCmdCancelDownload: TBytes;
function RaceBoxCmdEraseMemory: TBytes;
function RaceBoxCmdCancelErase: TBytes;
function RaceBoxCmdUnlock(SecurityCode: Cardinal): TBytes;
function RaceBoxCmdReadRecordingConfig: TBytes;
function RaceBoxCmdWriteRecordingConfig(const Config: TRaceBoxRecordingConfig): TBytes;
function RaceBoxCmdReadGnssConfig: TBytes;
function RaceBoxCmdWriteGnssConfig(const Config: TRaceBoxGnssConfig): TBytes;

{ Decoders. Each returns False when the payload has the wrong size. }
function RaceBoxDecodeSample(const Payload: TBytes; Source: TRaceBoxSampleSource;
  out Sample: TRaceBoxSample): Boolean;
function RaceBoxDecodeRecordingStatus(const Payload: TBytes; out Status: TRaceBoxRecordingStatus): Boolean;
function RaceBoxDecodeRecordingConfig(const Payload: TBytes; out Config: TRaceBoxRecordingConfig): Boolean;
function RaceBoxDecodeStateChange(const Payload: TBytes; out Change: TRaceBoxStateChange): Boolean;
function RaceBoxDecodeGnssConfig(const Payload: TBytes; out Config: TRaceBoxGnssConfig): Boolean;
function RaceBoxDecodeAck(const Payload: TBytes; out AckClass, AckId: Byte): Boolean;
function RaceBoxDecodeU32(const Payload: TBytes; out Value: Cardinal): Boolean;

{ Little-endian readers }
function RbU16(const B: TBytes; Ofs: Integer): Word; inline;
function RbI16(const B: TBytes; Ofs: Integer): SmallInt; inline;
function RbU32(const B: TBytes; Ofs: Integer): Cardinal; inline;
function RbI32(const B: TBytes; Ofs: Integer): Integer; inline;

function RaceBoxMessageName(MsgClass, MsgId: Byte): string;
function RaceBoxBytesToHex(const B: TBytes): string;

implementation

{ ---------------------------------------------------------------- readers }

function RbU16(const B: TBytes; Ofs: Integer): Word;
begin
  Result := Word(B[Ofs]) or (Word(B[Ofs + 1]) shl 8);
end;

function RbI16(const B: TBytes; Ofs: Integer): SmallInt;
begin
  Result := SmallInt(RbU16(B, Ofs));
end;

function RbU32(const B: TBytes; Ofs: Integer): Cardinal;
begin
  Result := Cardinal(B[Ofs]) or (Cardinal(B[Ofs + 1]) shl 8) or
    (Cardinal(B[Ofs + 2]) shl 16) or (Cardinal(B[Ofs + 3]) shl 24);
end;

function RbI32(const B: TBytes; Ofs: Integer): Integer;
begin
  Result := Integer(RbU32(B, Ofs));
end;

procedure PutU16(var B: TBytes; Ofs: Integer; V: Word);
begin
  B[Ofs] := Byte(V);
  B[Ofs + 1] := Byte(V shr 8);
end;

{ ---------------------------------------------------------------- framing }

procedure RaceBoxChecksum(const Data: TBytes; Start, Count: Integer; out CkA, CkB: Byte);
var
  I: Integer;
  A, B: Byte;
begin
  A := 0;
  B := 0;
  for I := Start to Start + Count - 1 do
  begin
    A := Byte(A + Data[I]);
    B := Byte(B + A);
  end;
  CkA := A;
  CkB := B;
end;

function RaceBoxBuildPacket(MsgClass, MsgId: Byte; const Payload: array of Byte): TBytes;
var
  N, I: Integer;
  A, B: Byte;
begin
  N := Length(Payload);
  if N > RB_MAX_PAYLOAD then
    raise EArgumentException.CreateFmt('RaceBox payload too long (%d bytes)', [N]);
  SetLength(Result, N + RB_OVERHEAD);
  Result[0] := RB_SYNC1;
  Result[1] := RB_SYNC2;
  Result[2] := MsgClass;
  Result[3] := MsgId;
  PutU16(Result, 4, N);
  for I := 0 to N - 1 do
    Result[RB_HEADER_SIZE + I] := Payload[I];
  RaceBoxChecksum(Result, 2, N + 4, A, B);
  Result[RB_HEADER_SIZE + N] := A;
  Result[RB_HEADER_SIZE + N + 1] := B;
end;

{ ---------------------------------------------------------------- commands }

function RaceBoxCmdRecordingStatus: TBytes;
begin
  Result := RaceBoxBuildPacket(RB_CLASS, RB_ID_REC_STATUS, []);
end;

function RaceBoxCmdStartDownload: TBytes;
begin
  Result := RaceBoxBuildPacket(RB_CLASS, RB_ID_DOWNLOAD, []);
end;

function RaceBoxCmdCancelDownload: TBytes;
begin
  // Any 1-byte payload cancels; the documentation example uses FF.
  Result := RaceBoxBuildPacket(RB_CLASS, RB_ID_DOWNLOAD, [$FF]);
end;

function RaceBoxCmdEraseMemory: TBytes;
begin
  Result := RaceBoxBuildPacket(RB_CLASS, RB_ID_ERASE, []);
end;

function RaceBoxCmdCancelErase: TBytes;
begin
  Result := RaceBoxBuildPacket(RB_CLASS, RB_ID_ERASE, [$FF]);
end;

function RaceBoxCmdUnlock(SecurityCode: Cardinal): TBytes;
begin
  Result := RaceBoxBuildPacket(RB_CLASS, RB_ID_UNLOCK,
    [Byte(SecurityCode), Byte(SecurityCode shr 8), Byte(SecurityCode shr 16), Byte(SecurityCode shr 24)]);
end;

function RaceBoxCmdReadRecordingConfig: TBytes;
begin
  Result := RaceBoxBuildPacket(RB_CLASS, RB_ID_REC_CONFIG, []);
end;

function RaceBoxCmdWriteRecordingConfig(const Config: TRaceBoxRecordingConfig): TBytes;
var
  P: TBytes;
begin
  SetLength(P, 12);
  FillChar(P[0], 12, 0);
  P[0] := Ord(Config.Enable);
  P[1] := Config.DataRate;
  P[2] := Config.Flags;
  PutU16(P, 4, Config.StationarySpeedMmS);
  PutU16(P, 6, Config.StationaryIntervalS);
  PutU16(P, 8, Config.NoFixIntervalS);
  PutU16(P, 10, Config.AutoShutdownIntervalS);
  Result := RaceBoxBuildPacket(RB_CLASS, RB_ID_REC_CONFIG, P);
end;

function RaceBoxCmdReadGnssConfig: TBytes;
begin
  Result := RaceBoxBuildPacket(RB_CLASS, RB_ID_GNSS_CONFIG, []);
end;

function RaceBoxCmdWriteGnssConfig(const Config: TRaceBoxGnssConfig): TBytes;
begin
  Result := RaceBoxBuildPacket(RB_CLASS, RB_ID_GNSS_CONFIG,
    [Config.PlatformModel, Ord(Config.Speed3D), Config.MinHorizAccuracyM]);
end;

{ ---------------------------------------------------------------- decoders }

function TryMakeUtc(var S: TRaceBoxSample): Boolean;
var
  D, T: TDateTime;
  Ms: Int64;
begin
  Result := False;
  S.UtcTime := 0;
  S.UnixTimeMs := 0;
  if not TryEncodeDate(S.Year, S.Month, S.Day, D) then Exit;
  if not TryEncodeTime(S.Hour, S.Minute, S.Second, 0, T) then Exit;
  // Whole seconds since the Unix epoch, then add the signed nanoseconds.
  Ms := (Round(D - 25569.0) * Int64(86400) +
    (Int64(S.Hour) * 3600 + Int64(S.Minute) * 60 + S.Second)) * 1000;
  Ms := Ms + Round(S.Nanoseconds / 1000000.0);
  S.UnixTimeMs := Ms;
  S.UtcTime := 25569.0 + Ms / 86400000.0;
  Result := True;
end;

function RaceBoxDecodeSample(const Payload: TBytes; Source: TRaceBoxSampleSource;
  out Sample: TRaceBoxSample): Boolean;
var
  P: TBytes;
begin
  Result := Length(Payload) = RB_DATA_PAYLOAD_SIZE;
  FillChar(Sample, SizeOf(Sample), 0);
  if not Result then Exit;
  P := Payload;
  Sample.Source := Source;
  Sample.ITOW := RbU32(P, 0);
  Sample.Year := RbU16(P, 4);
  Sample.Month := P[6];
  Sample.Day := P[7];
  Sample.Hour := P[8];
  Sample.Minute := P[9];
  Sample.Second := P[10];
  Sample.ValidityFlags := P[11];
  Sample.TimeAccuracyNs := RbU32(P, 12);
  Sample.Nanoseconds := RbI32(P, 16);
  Sample.FixStatus := P[20];
  Sample.FixStatusFlags := P[21];
  Sample.DateTimeFlags := P[22];
  Sample.NumSV := P[23];
  Sample.Longitude := RbI32(P, 24) / 1E7;
  Sample.Latitude := RbI32(P, 28) / 1E7;
  Sample.AltitudeWGS := RbI32(P, 32) / 1000.0;
  Sample.AltitudeMSL := RbI32(P, 36) / 1000.0;
  Sample.HorizAccuracy := RbU32(P, 40) / 1000.0;
  Sample.VertAccuracy := RbU32(P, 44) / 1000.0;
  Sample.Speed := RbI32(P, 48) / 1000.0;
  Sample.Heading := RbI32(P, 52) / 1E5;
  Sample.SpeedAccuracy := RbU32(P, 56) / 1000.0;
  Sample.HeadingAccuracy := RbU32(P, 60) / 1E5;
  Sample.PDOP := RbU16(P, 64) / 100.0;
  Sample.LatLonFlags := P[66];
  Sample.BatteryRaw := P[67];
  Sample.GForceX := RbI16(P, 68) / 1000.0;
  Sample.GForceY := RbI16(P, 70) / 1000.0;
  Sample.GForceZ := RbI16(P, 72) / 1000.0;
  Sample.GyroX := RbI16(P, 74) / 100.0;
  Sample.GyroY := RbI16(P, 76) / 100.0;
  Sample.GyroZ := RbI16(P, 78) / 100.0;
  // bit 0 valid date, bit 1 valid time
  Sample.TimeValid := ((Sample.ValidityFlags and $03) = $03) and TryMakeUtc(Sample);
  if not Sample.TimeValid then
  begin
    Sample.UtcTime := 0;
    Sample.UnixTimeMs := 0;
  end;
end;

function RaceBoxDecodeRecordingStatus(const Payload: TBytes; out Status: TRaceBoxRecordingStatus): Boolean;
begin
  Result := Length(Payload) >= 12;
  FillChar(Status, SizeOf(Status), 0);
  if not Result then Exit;
  Status.Recording := Payload[0] <> 0;
  Status.MemoryLevel := Payload[1];
  Status.SecurityEnabled := (Payload[2] and $01) <> 0;
  Status.Unlocked := (Payload[2] and $02) <> 0;
  Status.StoredMessages := RbU32(Payload, 4);
  Status.MemorySize := RbU32(Payload, 8);
end;

function RaceBoxDecodeRecordingConfig(const Payload: TBytes; out Config: TRaceBoxRecordingConfig): Boolean;
begin
  Result := Length(Payload) >= 12;
  FillChar(Config, SizeOf(Config), 0);
  if not Result then Exit;
  Config.Enable := Payload[0] <> 0;
  Config.DataRate := Payload[1];
  Config.Flags := Payload[2];
  Config.StationarySpeedMmS := RbU16(Payload, 4);
  Config.StationaryIntervalS := RbU16(Payload, 6);
  Config.NoFixIntervalS := RbU16(Payload, 8);
  Config.AutoShutdownIntervalS := RbU16(Payload, 10);
end;

function RaceBoxDecodeStateChange(const Payload: TBytes; out Change: TRaceBoxStateChange): Boolean;
begin
  Result := Length(Payload) >= 12;
  FillChar(Change, SizeOf(Change), 0);
  if not Result then Exit;
  Change.State := Payload[0];
  Change.DataRate := Payload[2];
  Change.Flags := Payload[3];
  Change.StationarySpeedMmS := RbU16(Payload, 4);
  Change.StationaryIntervalS := RbU16(Payload, 6);
  Change.NoFixIntervalS := RbU16(Payload, 8);
  Change.AutoShutdownIntervalS := RbU16(Payload, 10);
end;

function RaceBoxDecodeGnssConfig(const Payload: TBytes; out Config: TRaceBoxGnssConfig): Boolean;
begin
  Result := Length(Payload) >= 3;
  FillChar(Config, SizeOf(Config), 0);
  if not Result then Exit;
  Config.PlatformModel := Payload[0];
  Config.Speed3D := Payload[1] <> 0;
  Config.MinHorizAccuracyM := Payload[2];
end;

function RaceBoxDecodeAck(const Payload: TBytes; out AckClass, AckId: Byte): Boolean;
begin
  Result := Length(Payload) >= 2;
  AckClass := 0;
  AckId := 0;
  if not Result then Exit;
  AckClass := Payload[0];
  AckId := Payload[1];
end;

function RaceBoxDecodeU32(const Payload: TBytes; out Value: Cardinal): Boolean;
begin
  Result := Length(Payload) = 4;
  Value := 0;
  if Result then Value := RbU32(Payload, 0);
end;

{ ---------------------------------------------------------------- records }

function TRaceBoxSample.SpeedKmh: Double;
begin
  Result := Speed * 3.6;
end;

function TRaceBoxSample.HasGoodFix: Boolean;
begin
  Result := (FixStatus = 3) and ((FixStatusFlags and $01) <> 0);
end;

function TRaceBoxSample.PositionValid: Boolean;
begin
  Result := (FixStatus >= 2) and ((LatLonFlags and $01) = 0);
end;

function TRaceBoxSample.HeadingValid: Boolean;
begin
  Result := (FixStatusFlags and $20) <> 0;
end;

function TRaceBoxSample.BatteryPercent: Integer;
begin
  Result := BatteryRaw and $7F;
end;

function TRaceBoxSample.IsCharging: Boolean;
begin
  Result := (BatteryRaw and $80) <> 0;
end;

function TRaceBoxSample.InputVoltage: Double;
begin
  Result := BatteryRaw / 10.0;
end;

class function TRaceBoxRecordingConfig.Default: TRaceBoxRecordingConfig;
begin
  // The example configuration from the protocol documentation:
  // 25 Hz, wait for fix, stationary filter 5 km/h for 30 s,
  // no-fix filter 30 s, auto-shutdown after 300 s.
  Result.Enable := True;
  Result.DataRate := RB_RATE_25HZ;
  Result.Flags := RB_REC_WAIT_FOR_FIX or RB_REC_STATIONARY_FILTER or
    RB_REC_NOFIX_FILTER or RB_REC_AUTO_SHUTDOWN or RB_REC_WAIT_FOR_DATA;
  Result.StationarySpeedMmS := 1389;
  Result.StationaryIntervalS := 30;
  Result.NoFixIntervalS := 30;
  Result.AutoShutdownIntervalS := 300;
end;

{ ---------------------------------------------------------------- parser }

procedure TRaceBoxPacketParser.Feed(const Data: TBytes);
begin
  if Length(Data) > 0 then
    Feed(@Data[0], Length(Data));
end;

procedure TRaceBoxPacketParser.Feed(Data: PByte; Count: Integer);
var
  Need: Integer;
begin
  if Count <= 0 then Exit;
  Need := FCount + Count;
  if Need > Length(FBuf) then
  begin
    if Need < 1024 then Need := 1024;
    SetLength(FBuf, Need * 2);
  end;
  Move(Data^, FBuf[FCount], Count);
  Inc(FCount, Count);
end;

procedure TRaceBoxPacketParser.Discard(N: Integer);
begin
  if N >= FCount then
    FCount := 0
  else
  begin
    Move(FBuf[N], FBuf[0], FCount - N);
    Dec(FCount, N);
  end;
end;

function TRaceBoxPacketParser.Next(out Packet: TRaceBoxPacket): Boolean;
var
  I, Len, Total: Integer;
  A, B: Byte;
begin
  Result := False;
  Packet.MsgClass := 0;
  Packet.MsgId := 0;
  Packet.Payload := nil;
  while FCount > 0 do
  begin
    // Skip to the next sync pair.
    I := 0;
    while (I < FCount) and not ((FBuf[I] = RB_SYNC1) and ((I + 1 >= FCount) or (FBuf[I + 1] = RB_SYNC2))) do
      Inc(I);
    if I > 0 then
    begin
      Inc(FBytesDiscarded, I);
      Discard(I);
    end;
    if FCount < RB_HEADER_SIZE then Exit;     // wait for more bytes
    Len := RbU16(FBuf, 4);
    if Len > RB_MAX_PAYLOAD then
    begin
      // Not a real header: drop the sync byte and look again.
      Inc(FBytesDiscarded);
      Discard(1);
      Continue;
    end;
    Total := Len + RB_OVERHEAD;
    if FCount < Total then Exit;              // wait for the rest of the packet
    RaceBoxChecksum(FBuf, 2, Len + 4, A, B);
    if (A <> FBuf[RB_HEADER_SIZE + Len]) or (B <> FBuf[RB_HEADER_SIZE + Len + 1]) then
    begin
      Inc(FChecksumErrors);
      Inc(FBytesDiscarded);
      Discard(1);
      Continue;
    end;
    Packet.MsgClass := FBuf[2];
    Packet.MsgId := FBuf[3];
    SetLength(Packet.Payload, Len);
    if Len > 0 then
      Move(FBuf[RB_HEADER_SIZE], Packet.Payload[0], Len);
    Discard(Total);
    Inc(FPackets);
    Exit(True);
  end;
end;

procedure TRaceBoxPacketParser.Reset;
begin
  FCount := 0;
  FChecksumErrors := 0;
  FBytesDiscarded := 0;
  FPackets := 0;
end;

{ ---------------------------------------------------------------- misc }

function RaceBoxMessageName(MsgClass, MsgId: Byte): string;
begin
  if MsgClass <> RB_CLASS then
    Exit(Format('%.2x %.2x', [MsgClass, MsgId]));
  case MsgId of
    RB_ID_DATA:         Result := 'Data';
    RB_ID_ACK:          Result := 'ACK';
    RB_ID_NACK:         Result := 'NACK';
    RB_ID_HISTORY:      Result := 'History data';
    RB_ID_REC_STATUS:   Result := 'Recording status';
    RB_ID_DOWNLOAD:     Result := 'Data download';
    RB_ID_ERASE:        Result := 'Erase memory';
    RB_ID_REC_CONFIG:   Result := 'Recording configuration';
    RB_ID_STATE_CHANGE: Result := 'Recording state change';
    RB_ID_GNSS_CONFIG:  Result := 'GNSS configuration';
    RB_ID_UNLOCK:       Result := 'Unlock memory';
  else
    Result := Format('FF %.2x', [MsgId]);
  end;
end;

function RaceBoxBytesToHex(const B: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(B) do
  begin
    if I > 0 then Result := Result + ' ';
    Result := Result + IntToHex(B[I], 2);
  end;
end;

end.
