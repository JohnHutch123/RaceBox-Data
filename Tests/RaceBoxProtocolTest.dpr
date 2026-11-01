program RaceBoxProtocolTest;

{ Checks RaceBox.Protocol and RaceBox.Session without a device: the example
  packets from the RaceBox protocol documentation, the stream parser, sample
  decoding, session splitting, raw dump decoding and CSV round trip.

  Delphi:      open in RAD Studio and run, or
               dcc32 -U..\Source RaceBoxProtocolTest.dpr
  Free Pascal: fpc -Mdelphi -Fu../Source RaceBoxProtocolTest.dpr }

{$APPTYPE CONSOLE}
{$IFDEF FPC}{$MODE DELPHI}{$MINFPCONSTPREC 64}{$ENDIF}

uses
{$IFDEF FPC}
  SysUtils, Classes, Math,
{$ELSE}
  System.SysUtils, System.Classes, System.Math, System.IOUtils,
{$ENDIF}
  RaceBox.Protocol, RaceBox.Session;

var
  Failures: Integer = 0;

procedure Check(const Name: string; OK: Boolean);
begin
  if OK then Writeln('  ok   ', Name)
  else begin Writeln('  FAIL ', Name); Inc(Failures); end;
end;

function Near(A, B: Double; Tol: Double = 1e-6): Boolean;
begin
  Result := Abs(A - B) <= Tol;
end;

function Hex(const S: string): TBytes;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    L.Delimiter := ' ';
    L.StrictDelimiter := True;
    L.DelimitedText := S;
    SetLength(Result, L.Count);
    for I := 0 to L.Count - 1 do
      Result[I] := StrToInt('$' + L[I]);
  finally
    L.Free;
  end;
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

procedure CheckPacket(const Name: string; const Got: TBytes; const Expected: string);
begin
  Check(Name + ' = ' + Expected, SameBytes(Got, Hex(Expected)));
  if not SameBytes(Got, Hex(Expected)) then
    Writeln('         got ', RaceBoxBytesToHex(Got));
end;

{ ---- encoder used only by the tests, mirrors the documented layout ---- }

procedure Put16(var B: TBytes; Ofs: Integer; V: Integer);
begin
  B[Ofs] := Byte(V); B[Ofs + 1] := Byte(V shr 8);
end;

procedure Put32(var B: TBytes; Ofs: Integer; V: Int64);
begin
  B[Ofs] := Byte(V); B[Ofs + 1] := Byte(V shr 8);
  B[Ofs + 2] := Byte(V shr 16); B[Ofs + 3] := Byte(V shr 24);
end;

function DataPayload(Hour, Minute, Second: Byte; Nano: Integer; LatE7, LonE7: Integer;
  SpeedMmS: Integer): TBytes;
begin
  SetLength(Result, 80);
  FillChar(Result[0], 80, 0);
  Put32(Result, 0, 118286240);       // iTOW
  Put16(Result, 4, 2026);
  Result[6] := 10; Result[7] := 12;
  Result[8] := Hour; Result[9] := Minute; Result[10] := Second;
  Result[11] := $07;                  // date, time, fully resolved
  Put32(Result, 12, 25);              // time accuracy ns
  Put32(Result, 16, Nano);
  Result[20] := 3;                    // 3D fix
  Result[21] := $21;                  // valid fix, valid heading
  Result[22] := $E0;
  Result[23] := 11;                   // satellites
  Put32(Result, 24, LonE7);
  Put32(Result, 28, LatE7);
  Put32(Result, 32, 72400);           // WGS alt mm
  Put32(Result, 36, 25300);           // MSL alt mm
  Put32(Result, 40, 850);             // hAcc mm
  Put32(Result, 44, 1200);            // vAcc mm
  Put32(Result, 48, SpeedMmS);
  Put32(Result, 52, 27012345);        // heading 270.12345
  Put32(Result, 56, 150);             // sAcc mm/s
  Put32(Result, 60, 123456);          // headAcc 1.23456
  Put16(Result, 64, 132);             // PDOP 1.32
  Result[66] := 0;
  Result[67] := $80 or 87;            // charging, 87 %
  Put16(Result, 68, -1250);           // -1.25 g braking
  Put16(Result, 70, 980);
  Put16(Result, 72, 1003);
  Put16(Result, 74, -1520);           // -15.20 deg/s
  Put16(Result, 76, 35);
  Put16(Result, 78, 9001);
end;

function StatePayload(State: Byte): TBytes;
begin
  SetLength(Result, 12);
  FillChar(Result[0], 12, 0);
  Result[0] := State;
  Result[2] := RB_RATE_25HZ;
  Result[3] := $1F;
  Put16(Result, 4, 1389);
end;

procedure Append(var Dest: TBytes; const Src: TBytes);
var
  N: Integer;
begin
  N := Length(Dest);
  SetLength(Dest, N + Length(Src));
  if Length(Src) > 0 then Move(Src[0], Dest[N], Length(Src));
end;

{ ---------------------------------------------------------------- tests }

procedure TestDocumentedPackets;
var
  G: TRaceBoxGnssConfig;
  C: TRaceBoxRecordingConfig;
begin
  Writeln('Documented packets');
  CheckPacket('recording status', RaceBoxCmdRecordingStatus, 'B5 62 FF 22 00 00 21 62');
  CheckPacket('start download', RaceBoxCmdStartDownload, 'B5 62 FF 23 00 00 22 65');
  CheckPacket('cancel download', RaceBoxCmdCancelDownload, 'B5 62 FF 23 01 00 FF 22 89');
  CheckPacket('erase', RaceBoxCmdEraseMemory, 'B5 62 FF 24 00 00 23 68');
  CheckPacket('cancel erase', RaceBoxCmdCancelErase, 'B5 62 FF 24 01 00 FF 23 8D');
  CheckPacket('unlock 123456', RaceBoxCmdUnlock(123456), 'B5 62 FF 30 04 00 40 E2 01 00 56 08');
  G.PlatformModel := 8; G.Speed3D := True; G.MinHorizAccuracyM := 2;
  CheckPacket('gnss config', RaceBoxCmdWriteGnssConfig(G), 'B5 62 FF 27 03 00 08 01 02 34 0E');
  C := TRaceBoxRecordingConfig.Default;
  C.Flags := $1F;
  CheckPacket('recording config', RaceBoxCmdWriteRecordingConfig(C),
    'B5 62 FF 25 0C 00 01 00 1F 00 6D 05 1E 00 1E 00 2C 01 2B 15');
end;

procedure TestParser;
var
  P: TRaceBoxPacketParser;
  Pk: TRaceBoxPacket;
  Stream: TBytes;
  I, N: Integer;
  V: Cardinal;
  AC, AI: Byte;
  Pct, LastId: Byte;
begin
  Writeln('Parser');
  P := TRaceBoxPacketParser.Create;
  try
    // Garbage, download reply (780), erase progress 59 %, a corrupted packet, ACK for unlock.
    Stream := Hex('00 13 B5 B5 62 FF 23 04 00 0C 03 00 00 35 3E 7A');
    Append(Stream, Hex('B5 62 FF 24 01 00 3B 5F C9'));
    Append(Stream, Hex('B5 62 FF 24 01 00 3B 5F 00'));
    Append(Stream, Hex('B5 62 FF 02 02 00 FF 30 32 3A'));
    // Feed one byte at a time, as a slow notification stream would.
    N := 0;
    for I := 0 to High(Stream) do
    begin
      P.Feed(@Stream[I], 1);
      while P.Next(Pk) do
      begin
        Inc(N);
        case N of
          1: Check('download reply = 780', (Pk.MsgId = RB_ID_DOWNLOAD) and RaceBoxDecodeU32(Pk.Payload, V) and (V = 780));
          2: begin
               Pct := 0;
               if Length(Pk.Payload) = 1 then Pct := Pk.Payload[0];
               Check('erase progress 59 %', (Pk.MsgId = RB_ID_ERASE) and (Pct = 59));
             end;
          3: Check('ack for unlock', (Pk.MsgId = RB_ID_ACK) and RaceBoxDecodeAck(Pk.Payload, AC, AI) and
               (AC = RB_CLASS) and (AI = RB_ID_UNLOCK));
        end;
      end;
    end;
    Check('three good packets', N = 3);
    Check('one checksum error', P.ChecksumErrors = 1);
    Check('buffer empty', P.BufferedBytes = 0);

    // Two data packets in one notification, split mid-packet across two.
    P.Reset;
    Stream := RaceBoxBuildPacket(RB_CLASS, RB_ID_DATA, DataPayload(14, 3, 22, 0, 0, 0, 0));
    Append(Stream, RaceBoxBuildPacket(RB_CLASS, RB_ID_HISTORY, DataPayload(14, 3, 23, 0, 0, 0, 0)));
    P.Feed(Copy(Stream, 0, 100));
    N := 0;
    while P.Next(Pk) do Inc(N);
    Check('first packet from partial chunk', N = 1);
    P.Feed(Copy(Stream, 100, Length(Stream) - 100));
    LastId := 0;
    while P.Next(Pk) do begin Inc(N); LastId := Pk.MsgId; end;
    Check('second packet after rest arrives', (N = 2) and (LastId = RB_ID_HISTORY));
  finally
    P.Free;
  end;
end;

procedure TestSample;
var
  S: TRaceBoxSample;
  Expected: TDateTime;
begin
  Writeln('Sample decode');
  Check('decodes 80 bytes',
    RaceBoxDecodeSample(DataPayload(14, 3, 22, 450000000, 515678901, -11234567, 45000), rssLive, S));
  Check('latitude', Near(S.Latitude, 51.5678901));
  Check('longitude', Near(S.Longitude, -1.1234567));
  Check('speed 45 m/s = 162 km/h', Near(S.Speed, 45) and Near(S.SpeedKmh, 162));
  Check('heading', Near(S.Heading, 270.12345));
  Check('heading accuracy', Near(S.HeadingAccuracy, 1.23456));
  Check('altitudes', Near(S.AltitudeWGS, 72.4) and Near(S.AltitudeMSL, 25.3));
  Check('accuracies', Near(S.HorizAccuracy, 0.85) and Near(S.VertAccuracy, 1.2) and Near(S.SpeedAccuracy, 0.15));
  Check('pdop', Near(S.PDOP, 1.32));
  Check('g forces', Near(S.GForceX, -1.25) and Near(S.GForceY, 0.98) and Near(S.GForceZ, 1.003));
  Check('gyro', Near(S.GyroX, -15.2) and Near(S.GyroY, 0.35) and Near(S.GyroZ, 90.01));
  Check('good fix, 11 sats', S.HasGoodFix and S.PositionValid and S.HeadingValid and (S.NumSV = 11));
  Check('battery 87 % charging', (S.BatteryPercent = 87) and S.IsCharging);
  Expected := EncodeDate(2026, 10, 12) + EncodeTime(14, 3, 22, 450);
  Check('utc time', S.TimeValid and Near(S.UtcTime, Expected, 0.5 / 86400000));
  Check('unix ms', S.UnixTimeMs = Round((Expected - 25569) * 86400000));
  Check('negative nanoseconds',
    RaceBoxDecodeSample(DataPayload(14, 3, 22, -200000000, 0, 0, 0), rssLive, S) and
    (S.UnixTimeMs = Round((EncodeDate(2026, 10, 12) + EncodeTime(14, 3, 21, 800) - 25569) * 86400000)));
  Check('rejects short payload', not RaceBoxDecodeSample(Copy(DataPayload(1, 1, 1, 0, 0, 0, 0), 0, 79), rssLive, S));
end;

function BuildDump: TBytes;
var
  I: Integer;
begin
  // Download reply, session A (start, 50 samples, pause, 10 samples, stop),
  // session B (start, 20 samples, with a 10 minute gap in the middle), ACK.
  Result := Hex('B5 62 FF 23 04 00 0C 03 00 00 35 3E');
  Append(Result, RaceBoxBuildPacket(RB_CLASS, RB_ID_STATE_CHANGE, StatePayload(RB_STATE_RUNNING)));
  for I := 0 to 49 do
    Append(Result, RaceBoxBuildPacket(RB_CLASS, RB_ID_HISTORY,
      DataPayload(10, 0, I div 25, (I mod 25) * 40000000, 515000000 + I * 10, -11000000, 30000)));
  Append(Result, RaceBoxBuildPacket(RB_CLASS, RB_ID_STATE_CHANGE, StatePayload(RB_STATE_PAUSED)));
  for I := 0 to 9 do
    Append(Result, RaceBoxBuildPacket(RB_CLASS, RB_ID_HISTORY,
      DataPayload(10, 2, I, 0, 515000000, -11000000, 10000)));
  Append(Result, RaceBoxBuildPacket(RB_CLASS, RB_ID_STATE_CHANGE, StatePayload(RB_STATE_DISABLED)));
  Append(Result, RaceBoxBuildPacket(RB_CLASS, RB_ID_STATE_CHANGE, StatePayload(RB_STATE_RUNNING)));
  for I := 0 to 19 do
    Append(Result, RaceBoxBuildPacket(RB_CLASS, RB_ID_HISTORY,
      DataPayload(15, Ord(I >= 10) * 10, I mod 10, 0, 515000000, -11000000, 20000)));
  Append(Result, Hex('B5 62 FF 02 02 00 FF 23 25 2D'));
end;

procedure TestSessions;
var
  Dump: TBytes;
  L: TRaceBoxSessionList;
  P: TRaceBoxPacketParser;
  Pk: TRaceBoxPacket;
  AC, AI: Byte;
begin
  Writeln('Sessions');
  Dump := BuildDump;
  // Make sure the final ACK we wrote by hand is valid.
  P := TRaceBoxPacketParser.Create;
  try
    P.Feed(Copy(Dump, Length(Dump) - 10, 10));
    Check('hand-written download ACK is valid',
      P.Next(Pk) and (Pk.MsgId = RB_ID_ACK) and RaceBoxDecodeAck(Pk.Payload, AC, AI) and (AI = RB_ID_DOWNLOAD));
  finally
    P.Free;
  end;

  L := RaceBoxDecodeDump(Dump, 300);
  try
    Check('three sessions (start/stop + 10 minute gap)', L.Count = 3);
    if L.Count = 3 then
    begin
      Check('session 1 has 60 samples and 1 pause', (L[0].Count = 60) and (L[0].PauseCount = 1));
      Check('session 1 start state', L[0].HasStartState and (L[0].StartState.StationarySpeedMmS = 1389));
      Check('session 1 start time', Near(L[0].StartTime, EncodeDate(2026, 10, 12) + EncodeTime(10, 0, 0, 0), 1e-9));
      Check('session 1 duration 129 s', Near(L[0].DurationSeconds, 129, 0.01));
      Check('session 1 max speed 108 km/h', Near(L[0].MaxSpeedKmh, 108, 1e-6));
      // 49 steps of 1e-6 degree north, then back to the start point after the pause.
      Check('session 1 distance ~ 10.9 m', Near(L[0].DistanceMeters, 98 * 0.000001 * 111195.08, 0.01));
      Check('session 2 has 10 samples', L[1].Count = 10);
      Check('session 3 has 10 samples', L[2].Count = 10);
      Check('file stamp', L[0].FileStamp = '20261012_100000');
      Writeln('         ', L[0].Description);
    end;
  finally
    L.Free;
  end;
  L := RaceBoxDecodeDump(Dump, 0);
  try
    Check('gap split can be turned off', (L.Count = 2) and (L[1].Count = 20));
  finally
    L.Free;
  end;
end;

procedure TestCsv;
var
  L: TRaceBoxSessionList;
  Loaded: TRaceBoxSampleList;
  Dir, Name: string;
  Files: TArray<string>;
  A, B: TRaceBoxSample;
begin
  Writeln('CSV');
{$IFDEF FPC}
  Dir := IncludeTrailingPathDelimiter(GetTempDir);
{$ELSE}
  Dir := IncludeTrailingPathDelimiter(TPath.GetTempPath);
{$ENDIF}
  Dir := Dir + 'RaceBoxTest' + IntToStr(Random(1000000));
  ForceDirectories(Dir);
  L := RaceBoxDecodeDump(BuildDump, 300);
  try
    Files := RaceBoxSaveSessionsCsv(Dir, L);
    Check('one file per session', Length(Files) = 3);
    Name := Files[0];
    Check('file name', ExtractFileName(Name) = 'RaceBox_20261012_100000.csv');
    Loaded := RaceBoxLoadCsv(Name);
    try
      Check('row count', Loaded.Count = 60);
      if Loaded.Count = 60 then
      begin
        A := L[0].Samples[7];
        B := Loaded[7];
        Check('time round trip', (A.UnixTimeMs = B.UnixTimeMs) and B.TimeValid and (B.Second = A.Second));
        Check('position round trip', Near(A.Latitude, B.Latitude, 1e-7) and Near(A.Longitude, B.Longitude, 1e-7));
        Check('speed round trip', Near(A.Speed, B.Speed, 1e-3));
        Check('g round trip', Near(A.GForceX, B.GForceX, 1e-3) and Near(A.GyroZ, B.GyroZ, 1e-2));
        Check('fix round trip', B.HasGoodFix);
      end;
    finally
      Loaded.Free;
    end;
    for Name in Files do DeleteFile(Name);
    RemoveDir(Dir);
  finally
    L.Free;
  end;
  Writeln('         ', RaceBoxCsvHeader);
end;

begin
  Randomize;
  TestDocumentedPackets;
  TestParser;
  TestSample;
  TestSessions;
  TestCsv;
  Writeln;
  if Failures = 0 then
    Writeln('All RaceBox protocol tests passed.')
  else
    Writeln(Failures, ' RaceBox protocol test(s) FAILED.');
  ExitCode := Ord(Failures > 0);
end.
