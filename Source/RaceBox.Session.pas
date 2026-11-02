unit RaceBox.Session;

{ Recorded RaceBox data split into sessions, plus CSV export/import and
  re-decoding of raw downloads. No Bluetooth code, so it also builds with
  Free Pascal.

  The device keeps every recorded message in one memory, oldest first. A
  "Recording state change" message is stored when recording starts, stops,
  shuts down or pauses, so a new session begins at each start (state 1) and
  ends at each stop (state 0). As a fallback a session is also split when
  the time between two samples is longer than MaxGapSeconds.

  RaceBox-Data, zlib licence (see LICENSE). }

{$IFDEF FPC}{$MODE DELPHI}{$MINFPCONSTPREC 64}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes, Math, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
{$ENDIF}
  RaceBox.Protocol;

type
  TRaceBoxSampleList = TList<TRaceBoxSample>;

  TRaceBoxSession = class
  private
    FSamples: TRaceBoxSampleList;
    FHasStartState: Boolean;
    FStartState: TRaceBoxStateChange;
    FPauseCount: Integer;
    function GetStartTime: TDateTime;
    function GetEndTime: TDateTime;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    function DurationSeconds: Double;
    function MaxSpeedKmh: Double;
    function DistanceMeters: Double;   // sum of hops between valid positions
    function LapCount: Integer;        // distinct lap numbers > 0 (imported files)
    function Description: string;      // "2026-10-12 14:03:22  12:41  48210 samples"
    { File name friendly start time, e.g. 20261012_140322 }
    function FileStamp: string;
    property Samples: TRaceBoxSampleList read FSamples;
    property StartTime: TDateTime read GetStartTime;   // UTC, 0 if unknown
    property EndTime: TDateTime read GetEndTime;
    property HasStartState: Boolean read FHasStartState;
    property StartState: TRaceBoxStateChange read FStartState;
    property PauseCount: Integer read FPauseCount;
  end;

  TRaceBoxSessionList = TObjectList<TRaceBoxSession>;

  { Feed it samples and state changes in the order they arrive. }
  TRaceBoxSessionSplitter = class
  private
    FSessions: TRaceBoxSessionList;
    FCurrent: TRaceBoxSession;
    FMaxGapMs: Int64;
    FLastTimeMs: Int64;
    FSampleCount: Integer;
    FPendingStart: Boolean;
    FPendingState: TRaceBoxStateChange;
    procedure CloseCurrent;
  public
    constructor Create(MaxGapSeconds: Double = 300);
    destructor Destroy; override;
    procedure AddSample(const Sample: TRaceBoxSample);
    procedure AddStateChange(const Change: TRaceBoxStateChange);
    { Hands over the finished sessions (caller frees the list) and resets. }
    function ExtractSessions: TRaceBoxSessionList;
    property SampleCount: Integer read FSampleCount;
  end;

{ Decodes a raw byte dump (the bytes received during a download, as saved by
  TRaceBoxClient.SaveRawDump) into sessions. Caller frees the result. }
function RaceBoxDecodeDump(const Data: TBytes; MaxGapSeconds: Double = 300): TRaceBoxSessionList;
function RaceBoxLoadDumpFile(const FileName: string; MaxGapSeconds: Double = 300): TRaceBoxSessionList;

{ CSV with a header row, '.' as decimal separator, times in UTC. }
procedure RaceBoxSaveCsv(const FileName: string; Samples: TRaceBoxSampleList);
function RaceBoxLoadCsv(const FileName: string): TRaceBoxSampleList;
{ Writes one CSV per session into Folder; returns the file names written. }
function RaceBoxSaveSessionsCsv(const Folder: string; Sessions: TRaceBoxSessionList;
  const Prefix: string = 'RaceBox_'): TArray<string>;

function RaceBoxCsvHeader: string;
function RaceBoxSampleToCsv(const S: TRaceBoxSample): string;

{ Great-circle distance in metres. }
function RaceBoxDistance(Lat1, Lon1, Lat2, Lon2: Double): Double;
function RaceBoxIsoTime(T: TDateTime): string;

implementation

var
  CsvFormat: TFormatSettings;

function RaceBoxDistance(Lat1, Lon1, Lat2, Lon2: Double): Double;
const
  R = 6371008.8; // mean Earth radius, m
var
  DLat, DLon, A: Double;
begin
  DLat := DegToRad(Lat2 - Lat1);
  DLon := DegToRad(Lon2 - Lon1);
  A := Sqr(Sin(DLat / 2)) + Cos(DegToRad(Lat1)) * Cos(DegToRad(Lat2)) * Sqr(Sin(DLon / 2));
  Result := 2 * R * ArcSin(Min(1.0, Sqrt(A)));
end;

function RaceBoxIsoTime(T: TDateTime): string;
begin
  if T = 0 then
    Result := ''
  else
    Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz"Z"', T, CsvFormat);
end;

{ ---------------------------------------------------------------- session }

constructor TRaceBoxSession.Create;
begin
  inherited Create;
  FSamples := TRaceBoxSampleList.Create;
end;

destructor TRaceBoxSession.Destroy;
begin
  FSamples.Free;
  inherited;
end;

function TRaceBoxSession.Count: Integer;
begin
  Result := FSamples.Count;
end;

function TRaceBoxSession.GetStartTime: TDateTime;
var
  I: Integer;
begin
  for I := 0 to FSamples.Count - 1 do
    if FSamples[I].TimeValid then Exit(FSamples[I].UtcTime);
  Result := 0;
end;

function TRaceBoxSession.GetEndTime: TDateTime;
var
  I: Integer;
begin
  for I := FSamples.Count - 1 downto 0 do
    if FSamples[I].TimeValid then Exit(FSamples[I].UtcTime);
  Result := 0;
end;

function TRaceBoxSession.DurationSeconds: Double;
var
  S, E: TDateTime;
begin
  S := StartTime;
  E := EndTime;
  if (S = 0) or (E = 0) then
    Result := 0
  else
    Result := (E - S) * 86400.0;
end;

function TRaceBoxSession.MaxSpeedKmh: Double;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FSamples.Count - 1 do
    if FSamples[I].HasGoodFix and (FSamples[I].SpeedKmh > Result) then
      Result := FSamples[I].SpeedKmh;
end;

function TRaceBoxSession.DistanceMeters: Double;
var
  I: Integer;
  HavePrev: Boolean;
  PLat, PLon: Double;
  S: TRaceBoxSample;
begin
  Result := 0;
  HavePrev := False;
  PLat := 0;
  PLon := 0;
  for I := 0 to FSamples.Count - 1 do
  begin
    S := FSamples[I];
    if not S.HasGoodFix then Continue;
    if HavePrev then
      Result := Result + RaceBoxDistance(PLat, PLon, S.Latitude, S.Longitude);
    PLat := S.Latitude;
    PLon := S.Longitude;
    HavePrev := True;
  end;
end;

function TRaceBoxSession.LapCount: Integer;
var
  I, Last: Integer;
begin
  Result := 0;
  Last := 0;
  for I := 0 to FSamples.Count - 1 do
    if (FSamples[I].Lap > 0) and (FSamples[I].Lap <> Last) then
    begin
      Inc(Result);
      Last := FSamples[I].Lap;
    end;
end;

function TRaceBoxSession.FileStamp: string;
var
  T: TDateTime;
begin
  T := StartTime;
  if T = 0 then
    Result := 'notime'
  else
    Result := FormatDateTime('yyyymmdd"_"hhnnss', T, CsvFormat);
end;

function TRaceBoxSession.Description: string;
var
  T: TDateTime;
  D: Integer;
begin
  T := StartTime;
  D := Round(DurationSeconds);
  if T = 0 then
    Result := '(no GPS time)'
  else
    Result := FormatDateTime('yyyy"-"mm"-"dd" "hh":"nn":"ss', T, CsvFormat) + ' UTC';
  Result := Result + Format('  %d:%.2d:%.2d  %d samples  %.1f km  max %.0f km/h',
    [D div 3600, (D div 60) mod 60, D mod 60, Count, DistanceMeters / 1000, MaxSpeedKmh], CsvFormat);
end;

{ ---------------------------------------------------------------- splitter }

constructor TRaceBoxSessionSplitter.Create(MaxGapSeconds: Double);
begin
  inherited Create;
  FSessions := TRaceBoxSessionList.Create(True);
  FMaxGapMs := Round(MaxGapSeconds * 1000);
end;

destructor TRaceBoxSessionSplitter.Destroy;
begin
  CloseCurrent;
  FSessions.Free;
  inherited;
end;

procedure TRaceBoxSessionSplitter.CloseCurrent;
begin
  if FCurrent = nil then Exit;
  if FCurrent.Count > 0 then
    FSessions.Add(FCurrent)
  else
    FCurrent.Free;
  FCurrent := nil;
  FLastTimeMs := 0;
end;

procedure TRaceBoxSessionSplitter.AddStateChange(const Change: TRaceBoxStateChange);
begin
  case Change.State of
    RB_STATE_RUNNING:
      begin
        CloseCurrent;
        FPendingStart := True;
        FPendingState := Change;
      end;
    RB_STATE_DISABLED:
      begin
        CloseCurrent;
        FPendingStart := False;
      end;
    RB_STATE_PAUSED:
      if FCurrent <> nil then
        Inc(FCurrent.FPauseCount);
  end;
end;

procedure TRaceBoxSessionSplitter.AddSample(const Sample: TRaceBoxSample);
begin
  Inc(FSampleCount);
  if (FCurrent <> nil) and (FMaxGapMs > 0) and Sample.TimeValid and (FLastTimeMs <> 0) and
     (Abs(Sample.UnixTimeMs - FLastTimeMs) > FMaxGapMs) then
    CloseCurrent;
  if FCurrent = nil then
  begin
    FCurrent := TRaceBoxSession.Create;
    if FPendingStart then
    begin
      FCurrent.FHasStartState := True;
      FCurrent.FStartState := FPendingState;
      FPendingStart := False;
    end;
  end;
  FCurrent.FSamples.Add(Sample);
  if Sample.TimeValid then
    FLastTimeMs := Sample.UnixTimeMs;
end;

function TRaceBoxSessionSplitter.ExtractSessions: TRaceBoxSessionList;
begin
  CloseCurrent;
  Result := FSessions;
  FSessions := TRaceBoxSessionList.Create(True);
  FSampleCount := 0;
  FPendingStart := False;
end;

{ ---------------------------------------------------------------- dumps }

function RaceBoxDecodeDump(const Data: TBytes; MaxGapSeconds: Double): TRaceBoxSessionList;
var
  Parser: TRaceBoxPacketParser;
  Splitter: TRaceBoxSessionSplitter;
  P: TRaceBoxPacket;
  S: TRaceBoxSample;
  C: TRaceBoxStateChange;
begin
  Parser := TRaceBoxPacketParser.Create;
  Splitter := TRaceBoxSessionSplitter.Create(MaxGapSeconds);
  try
    Parser.Feed(Data);
    while Parser.Next(P) do
    begin
      if P.MsgClass <> RB_CLASS then Continue;
      case P.MsgId of
        RB_ID_HISTORY:
          if RaceBoxDecodeSample(P.Payload, rssHistory, S) then Splitter.AddSample(S);
        RB_ID_STATE_CHANGE:
          if RaceBoxDecodeStateChange(P.Payload, C) then Splitter.AddStateChange(C);
      end;
    end;
    Result := Splitter.ExtractSessions;
  finally
    Splitter.Free;
    Parser.Free;
  end;
end;

function RaceBoxLoadDumpFile(const FileName: string; MaxGapSeconds: Double): TRaceBoxSessionList;
var
  F: TFileStream;
  Data: TBytes;
begin
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Data, F.Size);
    if Length(Data) > 0 then
      F.ReadBuffer(Data[0], Length(Data));
  finally
    F.Free;
  end;
  Result := RaceBoxDecodeDump(Data, MaxGapSeconds);
end;

{ ---------------------------------------------------------------- CSV }

const
  CsvColumns: array[0..27] of string = (
    'utc_time', 'unix_ms', 'itow_ms', 'latitude', 'longitude',
    'alt_msl_m', 'alt_wgs_m', 'speed_kmh', 'speed_ms', 'heading_deg',
    'fix', 'fix_ok', 'sats', 'pdop', 'h_acc_m', 'v_acc_m', 'speed_acc_ms',
    'heading_acc_deg', 'g_x', 'g_y', 'g_z', 'gyro_x_dps', 'gyro_y_dps', 'gyro_z_dps',
    'battery_raw', 'fix_flags', 'latlon_flags', 'lap');

function RaceBoxCsvHeader: string;
var
  I: Integer;
begin
  Result := '';
  for I := Low(CsvColumns) to High(CsvColumns) do
  begin
    if I > 0 then Result := Result + ',';
    Result := Result + CsvColumns[I];
  end;
end;

function F(V: Double; Decimals: Integer): string;
begin
  Result := FloatToStrF(V, ffFixed, 15, Decimals, CsvFormat);
end;

function RaceBoxSampleToCsv(const S: TRaceBoxSample): string;
begin
  Result :=
    RaceBoxIsoTime(S.UtcTime) + ',' +
    IntToStr(S.UnixTimeMs) + ',' +
    IntToStr(S.ITOW) + ',' +
    F(S.Latitude, 7) + ',' +
    F(S.Longitude, 7) + ',' +
    F(S.AltitudeMSL, 3) + ',' +
    F(S.AltitudeWGS, 3) + ',' +
    F(S.SpeedKmh, 3) + ',' +
    F(S.Speed, 3) + ',' +
    F(S.Heading, 5) + ',' +
    IntToStr(S.FixStatus) + ',' +
    IntToStr(Ord(S.HasGoodFix)) + ',' +
    IntToStr(S.NumSV) + ',' +
    F(S.PDOP, 2) + ',' +
    F(S.HorizAccuracy, 3) + ',' +
    F(S.VertAccuracy, 3) + ',' +
    F(S.SpeedAccuracy, 3) + ',' +
    F(S.HeadingAccuracy, 5) + ',' +
    F(S.GForceX, 3) + ',' +
    F(S.GForceY, 3) + ',' +
    F(S.GForceZ, 3) + ',' +
    F(S.GyroX, 2) + ',' +
    F(S.GyroY, 2) + ',' +
    F(S.GyroZ, 2) + ',' +
    IntToStr(S.BatteryRaw) + ',' +
    IntToStr(S.FixStatusFlags) + ',' +
    IntToStr(S.LatLonFlags) + ',' +
    IntToStr(S.Lap);
end;

procedure WriteLine(Stream: TStream; const Line: string);
var
  U: UTF8String;
begin
  U := UTF8String(Line + #13#10);
  if Length(U) > 0 then
    Stream.WriteBuffer(Pointer(U)^, Length(U));
end;

procedure RaceBoxSaveCsv(const FileName: string; Samples: TRaceBoxSampleList);
var
  Stream: TFileStream;
  Buf: TMemoryStream;
  I: Integer;
begin
  Stream := TFileStream.Create(FileName, fmCreate);
  Buf := TMemoryStream.Create;
  try
    WriteLine(Buf, RaceBoxCsvHeader);
    for I := 0 to Samples.Count - 1 do
    begin
      WriteLine(Buf, RaceBoxSampleToCsv(Samples[I]));
      if Buf.Size > 1 shl 20 then
      begin
        Stream.WriteBuffer(Buf.Memory^, Buf.Size);
        Buf.Clear;
      end;
    end;
    if Buf.Size > 0 then
      Stream.WriteBuffer(Buf.Memory^, Buf.Size);
  finally
    Buf.Free;
    Stream.Free;
  end;
end;

function RaceBoxLoadCsv(const FileName: string): TRaceBoxSampleList;
var
  Lines, Cols: TStringList;
  Map: array[0..High(CsvColumns)] of Integer;
  I, J: Integer;
  W1, W2, W3, W4: Word;
  S: TRaceBoxSample;

  function Col(Index: Integer): string;
  begin
    if (Map[Index] >= 0) and (Map[Index] < Cols.Count) then
      Result := Cols[Map[Index]]
    else
      Result := '';
  end;

  function Num(Index: Integer): Double;
  var
    T: string;
  begin
    T := Col(Index);
    if T = '' then Result := 0 else Result := StrToFloat(T, CsvFormat);
  end;

  function Int(Index: Integer): Int64;
  begin
    Result := StrToInt64Def(Col(Index), 0);
  end;

begin
  Result := TRaceBoxSampleList.Create;
  Lines := TStringList.Create;
  Cols := TStringList.Create;
  try
    Cols.Delimiter := ',';
    Cols.StrictDelimiter := True;
    Lines.LoadFromFile(FileName);
    if Lines.Count = 0 then Exit;
    Cols.DelimitedText := Lines[0];
    for I := Low(CsvColumns) to High(CsvColumns) do
      Map[I] := Cols.IndexOf(CsvColumns[I]);
    for J := 1 to Lines.Count - 1 do
    begin
      if Trim(Lines[J]) = '' then Continue;
      Cols.DelimitedText := Lines[J];
      FillChar(S, SizeOf(S), 0);
      S.Source := rssHistory;
      S.UnixTimeMs := Int(1);
      S.TimeValid := S.UnixTimeMs <> 0;
      if S.TimeValid then
        S.UtcTime := 25569.0 + S.UnixTimeMs / 86400000.0;
      S.ITOW := Cardinal(Int(2));
      S.Latitude := Num(3);
      S.Longitude := Num(4);
      S.AltitudeMSL := Num(5);
      S.AltitudeWGS := Num(6);
      S.Speed := Num(8);
      S.Heading := Num(9);
      S.FixStatus := Byte(Int(10));
      S.NumSV := Byte(Int(12));
      S.PDOP := Num(13);
      S.HorizAccuracy := Num(14);
      S.VertAccuracy := Num(15);
      S.SpeedAccuracy := Num(16);
      S.HeadingAccuracy := Num(17);
      S.GForceX := Num(18);
      S.GForceY := Num(19);
      S.GForceZ := Num(20);
      S.GyroX := Num(21);
      S.GyroY := Num(22);
      S.GyroZ := Num(23);
      S.BatteryRaw := Byte(Int(24));
      S.FixStatusFlags := Byte(Int(25));
      S.LatLonFlags := Byte(Int(26));
      S.Lap := Integer(Int(27));
      if S.TimeValid then
      begin
        S.ValidityFlags := $03;
        DecodeDate(S.UtcTime, S.Year, W1, W2);
        S.Month := W1;
        S.Day := W2;
        DecodeTime(S.UtcTime, W1, W2, W3, W4);
        S.Hour := W1;
        S.Minute := W2;
        S.Second := W3;
        S.Nanoseconds := Integer(W4) * 1000000;
      end;
      Result.Add(S);
    end;
  finally
    Cols.Free;
    Lines.Free;
  end;
end;

function RaceBoxSaveSessionsCsv(const Folder: string; Sessions: TRaceBoxSessionList;
  const Prefix: string): TArray<string>;
var
  I, N: Integer;
  Name, Base: string;
begin
  SetLength(Result, Sessions.Count);
  for I := 0 to Sessions.Count - 1 do
  begin
    Base := IncludeTrailingPathDelimiter(Folder) + Prefix + Sessions[I].FileStamp;
    Name := Base + '.csv';
    N := 2;
    while FileExists(Name) do
    begin
      Name := Base + '_' + IntToStr(N) + '.csv';
      Inc(N);
    end;
    RaceBoxSaveCsv(Name, Sessions[I].Samples);
    Result[I] := Name;
  end;
end;

initialization
{$IFDEF FPC}
  CsvFormat := DefaultFormatSettings;
{$ELSE}
  CsvFormat := TFormatSettings.Invariant;
{$ENDIF}
  CsvFormat.DecimalSeparator := '.';
  CsvFormat.ThousandSeparator := #0;
end.
