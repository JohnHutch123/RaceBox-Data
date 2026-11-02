unit RaceBox.Import;

{ Reads sessions exported from the RaceBox app / website (racebox.pro >
  My Sessions > Export) into the same TRaceBoxSample records the Bluetooth
  download produces.

  - CSV: RaceBox lets you choose the columns (and has presets), so columns
    are matched by name, not position. Recognised names include Time / UTC /
    Timestamp, Latitude / Lat, Longitude / Lon / Lng, Altitude, Speed,
    Heading / Course, GForceX/Y/Z, GyroX/Y/Z, Satellites, Lap. Units are
    taken from the column name when it has one, e.g. "Speed (mph)".
  - VBO: the Racelogic VBOX text format (RaceChrono, Circuit Tools).
  - GPX: position and time only; speed and heading are worked out.

  No Bluetooth code, so it also builds with Free Pascal.

  RaceBox-Data, zlib licence (see LICENSE). }

{$IFDEF FPC}{$MODE DELPHI}{$MINFPCONSTPREC 64}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes, Math, DateUtils,
{$ELSE}
  System.SysUtils, System.Classes, System.Math, System.DateUtils,
{$ENDIF}
  RaceBox.Protocol, RaceBox.Session;

type
  TRaceBoxSpeedUnit = (rsuAuto, rsuKmh, rsuMph, rsuMs, rsuKnots);

  TRaceBoxImportOptions = record
    { Unit of a speed column whose name has no unit in it. RaceBox shows
      km/h by default, so rsuAuto means km/h unless the name says otherwise. }
    SpeedUnit: TRaceBoxSpeedUnit;
    { Used when the file only has a time of day and no date. 0 = take the
      date from the file header if there is one, else the file's date. }
    DefaultDate: TDateTime;
    class function Default: TRaceBoxImportOptions; static;
  end;

{ Imports one exported file (.csv, .vbo or .gpx, chosen by extension; anything
  else is tried as CSV). Info describes what was recognised, for a log.
  Raises an exception with a readable message if the file can't be used.
  Caller frees the result. }
function RaceBoxImportFile(const FileName: string; out Info: string): TRaceBoxSession; overload;
function RaceBoxImportFile(const FileName: string; const Options: TRaceBoxImportOptions;
  out Info: string): TRaceBoxSession; overload;

{ The same, from text already in memory (FileDate stands in for the file's date). }
function RaceBoxImportCsvText(const Text: string; const Options: TRaceBoxImportOptions;
  FileDate: TDateTime; out Info: string): TRaceBoxSession;
function RaceBoxImportVboText(const Text: string; const Options: TRaceBoxImportOptions;
  FileDate: TDateTime; out Info: string): TRaceBoxSession;
function RaceBoxImportGpxText(const Text: string; out Info: string): TRaceBoxSession;

{ Helpers, public for the tests. }
function RaceBoxTryParseIsoTime(const S: string; out UnixMs: Int64): Boolean;
function RaceBoxTryParseTimeOfDay(const S: string; out MsOfDay: Int64): Boolean;

implementation

var
  Inv: TFormatSettings;

class function TRaceBoxImportOptions.Default: TRaceBoxImportOptions;
begin
  Result.SpeedUnit := rsuAuto;
  Result.DefaultDate := 0;
end;

{ ---------------------------------------------------------------- small helpers }

const
  UnixEpoch = 25569.0;

function DateToUnixMs(D: TDateTime): Int64;
begin
  Result := Round((D - UnixEpoch) * 86400000.0);
end;

function UnixMsToDateTime(Ms: Int64): TDateTime;
begin
  Result := UnixEpoch + Ms / 86400000.0;
end;

function TryNum(const S: string; out V: Double): Boolean;
var
  T: string;
begin
  T := Trim(S);
  if (Length(T) >= 2) and (T[1] = '"') and (T[Length(T)] = '"') then
    T := Copy(T, 2, Length(T) - 2);
  Result := (T <> '') and TryStrToFloat(T, V, Inv);
end;

function DigitsAt(const S: string; P, N: Integer; out V: Integer): Boolean;
var
  I: Integer;
begin
  V := 0;
  Result := P + N - 1 <= Length(S);
  if not Result then Exit;
  for I := P to P + N - 1 do
  begin
    if not CharInSet(S[I], ['0'..'9']) then Exit(False);
    V := V * 10 + Ord(S[I]) - Ord('0');
  end;
end;

{ hh:mm:ss[.fff] (or h:mm:ss) -> ms since midnight. }
function RaceBoxTryParseTimeOfDay(const S: string; out MsOfDay: Int64): Boolean;
var
  T: string;
  P, H, M, Sec: Integer;
  Frac: Double;
  FracStr: string;
begin
  Result := False;
  MsOfDay := 0;
  T := Trim(S);
  P := Pos(':', T);
  if (P < 2) or (P > 3) then Exit;
  if not TryStrToInt(Copy(T, 1, P - 1), H) then Exit;
  if not DigitsAt(T, P + 1, 2, M) then Exit;
  if (Length(T) < P + 5) or (T[P + 3] <> ':') then Exit;
  if not DigitsAt(T, P + 4, 2, Sec) then Exit;
  Frac := 0;
  if Length(T) > P + 5 then
  begin
    if not CharInSet(T[P + 6], ['.', ',']) then Exit;
    FracStr := '0.' + Copy(T, P + 7, MaxInt);
    if not TryStrToFloat(FracStr, Frac, Inv) then Exit;
  end;
  if (H > 47) or (M > 59) or (Sec > 60) then Exit;
  MsOfDay := ((Int64(H) * 60 + M) * 60 + Sec) * 1000 + Round(Frac * 1000);
  Result := True;
end;

{ yyyy-mm-dd[T| ]hh:mm:ss[.fff][Z|+hh:mm|-hh:mm] -> Unix ms (UTC).
  Without a zone the time is taken as UTC, which is what RaceBox exports. }
function RaceBoxTryParseIsoTime(const S: string; out UnixMs: Int64): Boolean;
var
  T, Rest, Zone: string;
  Y, Mo, D, ZH, ZM, P, Sign: Integer;
  Dt: TDateTime;
  Tod: Int64;
begin
  Result := False;
  UnixMs := 0;
  T := Trim(S);
  if (Length(T) >= 2) and (T[1] = '"') then T := Copy(T, 2, Length(T) - 2);
  if Length(T) < 10 then Exit;
  if not (DigitsAt(T, 1, 4, Y) and (T[5] = '-') and DigitsAt(T, 6, 2, Mo) and
          (T[8] = '-') and DigitsAt(T, 9, 2, D)) then Exit;
  if not TryEncodeDate(Y, Mo, D, Dt) then Exit;
  Tod := 0;
  if Length(T) > 10 then
  begin
    if not CharInSet(T[11], ['T', 't', ' ']) then Exit;
    Rest := Copy(T, 12, MaxInt);
    // split off a time zone
    Zone := '';
    if (Rest <> '') and CharInSet(Rest[Length(Rest)], ['Z', 'z']) then
      Rest := Copy(Rest, 1, Length(Rest) - 1)
    else
    begin
      P := LastDelimiter('+-', Rest);
      if P > 6 then
      begin
        Zone := Copy(Rest, P, MaxInt);
        Rest := Copy(Rest, 1, P - 1);
      end;
    end;
    if not RaceBoxTryParseTimeOfDay(Rest, Tod) then Exit;
    if Zone <> '' then
    begin
      if Zone[1] = '-' then Sign := -1 else Sign := 1;
      Zone := StringReplace(Copy(Zone, 2, MaxInt), ':', '', []);
      if not (DigitsAt(Zone, 1, 2, ZH)) then Exit;
      ZM := 0;
      if Length(Zone) >= 4 then DigitsAt(Zone, 3, 2, ZM);
      Tod := Tod - Sign * (Int64(ZH) * 60 + ZM) * 60000;
    end;
  end;
  UnixMs := DateToUnixMs(Dt) + Tod;
  Result := True;
end;

{ Looks for a date in free text (a header line): yyyy-mm-dd, dd/mm/yyyy or dd.mm.yyyy. }
function FindDate(const Line: string; out D: TDateTime): Boolean;
var
  I, A, B, C: Integer;
begin
  Result := False;
  D := 0;
  for I := 1 to Length(Line) - 9 do
  begin
    if DigitsAt(Line, I, 4, A) and (Line[I + 4] = '-') and DigitsAt(Line, I + 5, 2, B) and
       (Line[I + 7] = '-') and DigitsAt(Line, I + 8, 2, C) then
      if TryEncodeDate(A, B, C, D) then Exit(True);
    if DigitsAt(Line, I, 2, A) and CharInSet(Line[I + 2], ['/', '.']) and DigitsAt(Line, I + 3, 2, B) and
       (Line[I + 5] = Line[I + 2]) and DigitsAt(Line, I + 6, 4, C) then
      if TryEncodeDate(C, B, A, D) then Exit(True);   // day first (RaceBox is EU based)
  end;
end;

procedure FinishSample(var S: TRaceBoxSample; HavePos: Boolean);
begin
  S.Source := rssHistory;
  if HavePos then
  begin
    S.FixStatus := 3;
    S.FixStatusFlags := S.FixStatusFlags or $01;
  end
  else
    S.LatLonFlags := $01;
  if S.UnixTimeMs <> 0 then
  begin
    S.TimeValid := True;
    S.ValidityFlags := $03;
    S.UtcTime := UnixMsToDateTime(S.UnixTimeMs);
  end;
end;

{ Fills in speed and heading from positions when the file has none (GPX). }
procedure DeriveMotion(Session: TRaceBoxSession; NeedSpeed, NeedHeading: Boolean);
var
  I: Integer;
  A, B: TRaceBoxSample;
  Dt, Dist, Y, X: Double;
begin
  for I := 1 to Session.Samples.Count - 1 do
  begin
    A := Session.Samples[I - 1];
    B := Session.Samples[I];
    if not (A.TimeValid and B.TimeValid) then Continue;
    Dt := (B.UnixTimeMs - A.UnixTimeMs) / 1000.0;
    if Dt <= 0 then Continue;
    if NeedSpeed then
    begin
      Dist := RaceBoxDistance(A.Latitude, A.Longitude, B.Latitude, B.Longitude);
      B.Speed := Dist / Dt;
    end;
    if NeedHeading then
    begin
      Y := Sin(DegToRad(B.Longitude - A.Longitude)) * Cos(DegToRad(B.Latitude));
      X := Cos(DegToRad(A.Latitude)) * Sin(DegToRad(B.Latitude)) -
        Sin(DegToRad(A.Latitude)) * Cos(DegToRad(B.Latitude)) * Cos(DegToRad(B.Longitude - A.Longitude));
      B.Heading := RadToDeg(ArcTan2(Y, X));
      if B.Heading < 0 then B.Heading := B.Heading + 360;
    end;
    Session.Samples[I] := B;
  end;
end;

function SpeedFactor(U: TRaceBoxSpeedUnit): Double;   // to m/s
begin
  case U of
    rsuMph:   Result := 0.44704;
    rsuMs:    Result := 1.0;
    rsuKnots: Result := 0.514444;
  else
    Result := 1 / 3.6;    // km/h
  end;
end;

function SpeedUnitName(U: TRaceBoxSpeedUnit): string;
begin
  case U of
    rsuMph:   Result := 'mph';
    rsuMs:    Result := 'm/s';
    rsuKnots: Result := 'knots';
  else
    Result := 'km/h';
  end;
end;

{ ---------------------------------------------------------------- CSV }

type
  TCsvField = (cfTime, cfDate, cfLat, cfLon, cfAlt, cfSpeed, cfHeading,
    cfGx, cfGy, cfGz, cfRx, cfRy, cfRz, cfSats, cfLap, cfHAcc);

const
  CsvFieldName: array[TCsvField] of string = ('time', 'date', 'latitude', 'longitude',
    'altitude', 'speed', 'heading', 'g x', 'g y', 'g z', 'gyro x', 'gyro y', 'gyro z',
    'satellites', 'lap', 'accuracy');

{ Lower case, keep only letters and digits: "GForce X (g)" -> "gforcexg". }
function Squash(const S: string): string;
var
  C: Char;
begin
  Result := '';
  for C in LowerCase(S) do
    if CharInSet(C, ['a'..'z', '0'..'9']) then
      Result := Result + C;
end;

{ The part of a header before any unit in brackets: "Speed (km/h)" -> "speed". }
function NamePart(const S: string): string;
var
  P: Integer;
begin
  Result := S;
  P := Pos('(', Result);
  if P = 0 then P := Pos('[', Result);
  if P > 0 then Result := Copy(Result, 1, P - 1);
  Result := Squash(Result);
end;

function MatchField(const Header: string; out F: TCsvField): Boolean;
var
  N: string;

  function IsAny(const Names: array of string): Boolean;
  var
    I: Integer;
  begin
    for I := Low(Names) to High(Names) do
      if N = Names[I] then Exit(True);
    Result := False;
  end;

begin
  N := NamePart(Header);
  Result := True;
  if IsAny(['time', 'utc', 'utctime', 'timestamp', 'datetime', 'gpstime', 'timeutc', 'timeofday', 'clock']) then F := cfTime
  else if IsAny(['date', 'utcdate', 'gpsdate']) then F := cfDate
  else if IsAny(['latitude', 'lat', 'latdeg', 'latitudedeg']) then F := cfLat
  else if IsAny(['longitude', 'lon', 'lng', 'long', 'londeg', 'longitudedeg']) then F := cfLon
  else if IsAny(['altitude', 'alt', 'height', 'elevation', 'altitudemsl', 'altmsl']) then F := cfAlt
  else if IsAny(['speed', 'gpsspeed', 'groundspeed', 'velocity', 'speedgps']) then F := cfSpeed
  else if IsAny(['heading', 'course', 'bearing', 'cog']) then F := cfHeading
  else if IsAny(['gforcex', 'gx', 'accx', 'accelx', 'longitudinalg', 'longg', 'longacc', 'xg']) then F := cfGx
  else if IsAny(['gforcey', 'gy', 'accy', 'accely', 'lateralg', 'latg', 'latacc', 'yg']) then F := cfGy
  else if IsAny(['gforcez', 'gz', 'accz', 'accelz', 'verticalg', 'vertg', 'zg']) then F := cfGz
  else if IsAny(['gyrox', 'rotationx', 'rollrate', 'roll']) then F := cfRx
  else if IsAny(['gyroy', 'rotationy', 'pitchrate', 'pitch']) then F := cfRy
  else if IsAny(['gyroz', 'rotationz', 'yawrate', 'yaw']) then F := cfRz
  else if IsAny(['satellites', 'sats', 'numsv', 'svs', 'satellitesused']) then F := cfSats
  else if IsAny(['lap', 'lapnumber', 'lapno', 'laps']) then F := cfLap
  else if IsAny(['accuracy', 'hacc', 'horizontalaccuracy', 'gpsaccuracy']) then F := cfHAcc
  else Result := False;
end;

function SpeedUnitFromHeader(const Header: string; Fallback: TRaceBoxSpeedUnit): TRaceBoxSpeedUnit;
var
  N: string;
begin
  N := Squash(Header);
  if Pos('mph', N) > 0 then Result := rsuMph
  else if (Pos('kmh', N) > 0) or (Pos('kph', N) > 0) then Result := rsuKmh
  else if Pos('knot', N) > 0 then Result := rsuKnots
  else if (Pos('ms', Copy(N, Length(NamePart(Header)) + 1, MaxInt)) > 0) or
          (Pos('m/s', Header) > 0) then Result := rsuMs
  else Result := Fallback;
end;

function SplitLine(const Line: string; Delim: Char): TStringList;
begin
  Result := TStringList.Create;
  Result.Delimiter := Delim;
  Result.StrictDelimiter := True;
  Result.QuoteChar := '"';
  Result.DelimitedText := Line;
end;

function GuessDelimiter(const Line: string): Char;
var
  C, Best: Char;
  N, BestN: Integer;
  Ch: Char;
begin
  Best := ',';
  BestN := 0;
  for C in [',', ';', #9] do
  begin
    N := 0;
    for Ch in Line do
      if Ch = C then Inc(N);
    if N > BestN then
    begin
      BestN := N;
      Best := C;
    end;
  end;
  Result := Best;
end;

function RaceBoxImportCsvText(const Text: string; const Options: TRaceBoxImportOptions;
  FileDate: TDateTime; out Info: string): TRaceBoxSession;
var
  Lines, Cols: TStringList;
  HeaderRow, I, J: Integer;
  Delim: Char;
  Map: array[TCsvField] of Integer;
  F: TCsvField;
  Found: TCsvField;
  BaseDate, D: TDateTime;
  HeaderDate: Boolean;
  SpeedU: TRaceBoxSpeedUnit;
  SpeedK: Double;
  S: TRaceBoxSample;
  V: Double;
  Ms, Tod, PrevTod, DayOffset, Unix: Int64;
  TimeKind: string;
  Recognised: string;
  Skipped: Integer;

  function Cell(Field: TCsvField): string;
  begin
    if (Map[Field] >= 0) and (Map[Field] < Cols.Count) then
      Result := Trim(Cols[Map[Field]])
    else
      Result := '';
  end;

  function Num(Field: TCsvField; out Value: Double): Boolean;
  begin
    Result := TryNum(Cell(Field), Value);
  end;

begin
  Result := nil;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    // Find the header: the first line with both a latitude and a longitude column.
    HeaderRow := -1;
    Delim := ',';
    for I := 0 to Min(Lines.Count - 1, 200) do
    begin
      Delim := GuessDelimiter(Lines[I]);
      Cols := SplitLine(Lines[I], Delim);
      try
        for F := Low(TCsvField) to High(TCsvField) do Map[F] := -1;
        for J := 0 to Cols.Count - 1 do
          if MatchField(Cols[J], Found) and (Map[Found] < 0) then
            Map[Found] := J;
        if (Map[cfLat] >= 0) and (Map[cfLon] >= 0) then
        begin
          HeaderRow := I;
          SpeedU := Options.SpeedUnit;
          if Map[cfSpeed] >= 0 then
            SpeedU := SpeedUnitFromHeader(Cols[Map[cfSpeed]], Options.SpeedUnit);
          Break;
        end;
      finally
        Cols.Free;
      end;
    end;
    if HeaderRow < 0 then
      raise Exception.Create('No header row with Latitude and Longitude columns was found. ' +
        'Export the session from RaceBox as CSV with the Latitude and Longitude columns included.');
    if SpeedU = rsuAuto then SpeedU := rsuKmh;
    SpeedK := SpeedFactor(SpeedU);

    // A date for files that only have a time of day: options, header lines, file date.
    BaseDate := Options.DefaultDate;
    HeaderDate := False;
    if BaseDate = 0 then
      for I := 0 to HeaderRow - 1 do
        if FindDate(Lines[I], D) then
        begin
          BaseDate := D;
          HeaderDate := True;
          Break;
        end;
    if BaseDate = 0 then BaseDate := Trunc(FileDate);

    Recognised := '';
    for F := Low(TCsvField) to High(TCsvField) do
      if Map[F] >= 0 then
      begin
        if Recognised <> '' then Recognised := Recognised + ', ';
        Recognised := Recognised + CsvFieldName[F];
      end;

    Result := TRaceBoxSession.Create;
    TimeKind := 'none';
    PrevTod := -1;
    DayOffset := 0;
    Skipped := 0;
    for I := HeaderRow + 1 to Lines.Count - 1 do
    begin
      if Trim(Lines[I]) = '' then Continue;
      Cols := SplitLine(Lines[I], Delim);
      try
        FillChar(S, SizeOf(S), 0);
        if not (Num(cfLat, S.Latitude) and Num(cfLon, S.Longitude)) then
        begin
          Inc(Skipped);    // a units row, a lap summary, or a blank position
          Continue;
        end;
        // Time
        Unix := 0;
        if RaceBoxTryParseIsoTime(Cell(cfTime), Ms) then
        begin
          Unix := Ms;
          TimeKind := 'date and time';
        end
        else if (Cell(cfDate) <> '') and RaceBoxTryParseIsoTime(Cell(cfDate) + ' ' + Cell(cfTime), Ms) then
        begin
          Unix := Ms;
          TimeKind := 'date and time';
        end
        else if RaceBoxTryParseTimeOfDay(Cell(cfTime), Tod) then
        begin
          // Time of day only: roll over midnight when it jumps back by hours.
          if (PrevTod >= 0) and (Tod < PrevTod - 12 * 3600000) then
            Inc(DayOffset, 86400000);
          PrevTod := Tod;
          Unix := DateToUnixMs(BaseDate) + DayOffset + Tod;
          if HeaderDate or (Options.DefaultDate <> 0) then
            TimeKind := 'time of day (date from file header)'
          else
            TimeKind := 'time of day (date taken from the file''s date)';
        end
        else if Num(cfTime, V) then
        begin
          if V > 1E11 then Unix := Round(V)                 // Unix ms
          else if V > 1E9 then Unix := Round(V * 1000)      // Unix seconds
          else Unix := DateToUnixMs(BaseDate) + Round(V * 1000);  // seconds into the session
          TimeKind := 'numeric';
        end;
        S.UnixTimeMs := Unix;

        if Num(cfAlt, V) then begin S.AltitudeMSL := V; S.AltitudeWGS := V; end;
        if Num(cfSpeed, V) then S.Speed := V * SpeedK;
        if Num(cfHeading, V) then S.Heading := V;
        if Num(cfGx, V) then S.GForceX := V;
        if Num(cfGy, V) then S.GForceY := V;
        if Num(cfGz, V) then S.GForceZ := V;
        if Num(cfRx, V) then S.GyroX := V;
        if Num(cfRy, V) then S.GyroY := V;
        if Num(cfRz, V) then S.GyroZ := V;
        if Num(cfSats, V) then S.NumSV := EnsureRange(Round(V), 0, 255);
        if Num(cfLap, V) then S.Lap := Round(V);
        if Num(cfHAcc, V) then S.HorizAccuracy := V;
        if Map[cfHeading] >= 0 then S.FixStatusFlags := $20;   // heading valid
        FinishSample(S, (S.Latitude <> 0) or (S.Longitude <> 0));
        Result.Samples.Add(S);
      finally
        Cols.Free;
      end;
    end;
    if Result.Count = 0 then
      raise Exception.Create('The file has a header row but no data rows with a position.');
    if Map[cfSpeed] < 0 then
      DeriveMotion(Result, True, Map[cfHeading] < 0)
    else if Map[cfHeading] < 0 then
      DeriveMotion(Result, False, True);

    Info := Format('CSV, header on line %d, %d rows read (%d skipped). Columns used: %s. ' +
      'Speed in %s. Time: %s.', [HeaderRow + 1, Result.Count, Skipped, Recognised,
      SpeedUnitName(SpeedU), TimeKind]);
  except
    Result.Free;
    Lines.Free;
    raise;
  end;
  Lines.Free;
end;

{ ---------------------------------------------------------------- VBO }

procedure SplitWhitespace(const Line: string; Into: TStringList);
var
  I, Start: Integer;
begin
  Into.Clear;
  I := 1;
  while I <= Length(Line) do
  begin
    while (I <= Length(Line)) and CharInSet(Line[I], [' ', #9]) do Inc(I);
    Start := I;
    while (I <= Length(Line)) and not CharInSet(Line[I], [' ', #9]) do Inc(I);
    if I > Start then Into.Add(Copy(Line, Start, I - Start));
  end;
end;

{ VBOX text files: a [column names] line and a [data] section of space
  separated rows. lat/long are in minutes and longitude is positive WEST;
  time is hhmmss.ss UTC; velocity is km/h. }
function RaceBoxImportVboText(const Text: string; const Options: TRaceBoxImportOptions;
  FileDate: TDateTime; out Info: string): TRaceBoxSession;
var
  Lines, Names, Vals: TStringList;
  I, Section: Integer;
  ColTime, ColLat, ColLon, ColVel, ColHead, ColHeight, ColSats, ColLatAcc, ColLongAcc, ColLap: Integer;
  BaseDate, D: TDateTime;
  S: TRaceBoxSample;
  L, T, V: Double;
  Tod, PrevTod, DayOffset: Int64;
  Line: string;

  function Col(const Names2: array of string): Integer;
  var
    K, J: Integer;
  begin
    for K := 0 to Names.Count - 1 do
      for J := Low(Names2) to High(Names2) do
        if SameText(Names[K], Names2[J]) then Exit(K);
    Result := -1;
  end;

  function Val(Index: Integer; out X: Double): Boolean;
  begin
    Result := (Index >= 0) and (Index < Vals.Count) and TryNum(Vals[Index], X);
  end;

begin
  Result := nil;
  Lines := TStringList.Create;
  Names := TStringList.Create;
  Vals := TStringList.Create;
  try
    Lines.Text := Text;
    BaseDate := Options.DefaultDate;
    Section := 0;   // 0 header text, 1 [column names], 2 [data], 3 other
    ColTime := -1;
    Result := TRaceBoxSession.Create;
    PrevTod := -1;
    DayOffset := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if Line = '' then Continue;
      if Line[1] = '[' then
      begin
        if SameText(Line, '[column names]') then Section := 1
        else if SameText(Line, '[data]') then Section := 2
        else Section := 3;
        Continue;
      end;
      case Section of
        0: if (BaseDate = 0) and FindDate(Line, D) then BaseDate := D;   // "File created on 15/04/2024 @ ..."
        1: begin
             SplitWhitespace(Line, Names);
             ColTime := Col(['time']);
             ColLat := Col(['lat', 'latitude']);
             ColLon := Col(['long', 'lon', 'longitude']);
             ColVel := Col(['velocity', 'speed', 'velocity kmh']);
             ColHead := Col(['heading']);
             ColHeight := Col(['height', 'altitude']);
             ColSats := Col(['sats', 'satellites']);
             ColLatAcc := Col(['LatAcc', 'lat_acc', 'lateral_acc']);
             ColLongAcc := Col(['LongAcc', 'long_acc', 'longitudinal_acc']);
             ColLap := Col(['lap', 'lapnumber']);
           end;
        2: begin
             if ColTime < 0 then
               raise Exception.Create('VBO file has no [column names] line with a time column.');
             SplitWhitespace(Line, Vals);
             FillChar(S, SizeOf(S), 0);
             if not (Val(ColLat, L) and Val(ColLon, V)) then Continue;
             S.Latitude := L / 60.0;
             S.Longitude := -V / 60.0;          // VBO longitude is positive west
             if Val(ColTime, T) then
             begin
               Tod := (Trunc(T / 10000) * 3600 + (Trunc(T / 100) mod 100) * 60) * Int64(1000) +
                 Round((T - Trunc(T / 100) * 100) * 1000);
               if (PrevTod >= 0) and (Tod < PrevTod - 12 * 3600000) then
                 Inc(DayOffset, 86400000);
               PrevTod := Tod;
               if BaseDate = 0 then BaseDate := Trunc(FileDate);
               S.UnixTimeMs := DateToUnixMs(BaseDate) + DayOffset + Tod;
             end;
             if Val(ColVel, V) then S.Speed := V / 3.6;
             if Val(ColHead, V) then begin S.Heading := V; S.FixStatusFlags := $20; end;
             if Val(ColHeight, V) then begin S.AltitudeMSL := V; S.AltitudeWGS := V; end;
             if Val(ColSats, V) then S.NumSV := EnsureRange(Round(V) mod 64, 0, 255);   // VBOX adds flags above 63
             if Val(ColLongAcc, V) then S.GForceX := V;
             if Val(ColLatAcc, V) then S.GForceY := V;
             if Val(ColLap, V) then S.Lap := Round(V);
             FinishSample(S, (S.Latitude <> 0) or (S.Longitude <> 0));
             Result.Samples.Add(S);
           end;
      end;
    end;
    if Result.Count = 0 then
      raise Exception.Create('No data rows found in the VBO file.');
    Info := Format('VBO, %d rows read. Columns: %s.', [Result.Count,
      StringReplace(Trim(Names.Text), sLineBreak, ' ', [rfReplaceAll])]);
  except
    Result.Free;
    Vals.Free;
    Names.Free;
    Lines.Free;
    raise;
  end;
  Vals.Free;
  Names.Free;
  Lines.Free;
end;

{ ---------------------------------------------------------------- GPX }

function AttrValue(const Tag, Name: string): string;
var
  P, Q: Integer;
  Quote: Char;
begin
  Result := '';
  P := Pos(' ' + Name + '=', Tag);
  if P = 0 then Exit;
  P := P + Length(Name) + 2;
  if P > Length(Tag) then Exit;
  Quote := Tag[P];
  Inc(P);
  Q := P;
  while (Q <= Length(Tag)) and (Tag[Q] <> Quote) do Inc(Q);
  Result := Copy(Tag, P, Q - P);
end;

function ElementText(const Block, Name: string): string;
var
  P, Q: Integer;
begin
  Result := '';
  P := Pos('<' + Name + '>', Block);
  if P = 0 then Exit;
  P := P + Length(Name) + 2;
  Q := Pos('</' + Name + '>', Copy(Block, P, MaxInt));
  if Q = 0 then Exit;
  Result := Trim(Copy(Block, P, Q - 1));
end;

function RaceBoxImportGpxText(const Text: string; out Info: string): TRaceBoxSession;
var
  P, TagEnd, BlockEnd: Integer;
  Rest, Tag, Block: string;
  S: TRaceBoxSample;
  Lat, Lon, V: Double;
  Ms: Int64;
begin
  Result := TRaceBoxSession.Create;
  try
    Rest := Text;
    repeat
      P := Pos('<trkpt', Rest);
      if P = 0 then Break;
      Rest := Copy(Rest, P, MaxInt);
      TagEnd := Pos('>', Rest);
      if TagEnd = 0 then Break;
      Tag := Copy(Rest, 1, TagEnd);
      BlockEnd := Pos('</trkpt>', Rest);
      if (BlockEnd = 0) or (Copy(Tag, Length(Tag) - 1, 2) = '/>') then BlockEnd := TagEnd;
      Block := Copy(Rest, 1, BlockEnd);
      Rest := Copy(Rest, BlockEnd + 1, MaxInt);
      if not (TryNum(AttrValue(Tag, 'lat'), Lat) and TryNum(AttrValue(Tag, 'lon'), Lon)) then Continue;
      FillChar(S, SizeOf(S), 0);
      S.Latitude := Lat;
      S.Longitude := Lon;
      if TryNum(ElementText(Block, 'ele'), V) then begin S.AltitudeMSL := V; S.AltitudeWGS := V; end;
      if RaceBoxTryParseIsoTime(ElementText(Block, 'time'), Ms) then S.UnixTimeMs := Ms;
      if TryNum(ElementText(Block, 'sat'), V) then S.NumSV := EnsureRange(Round(V), 0, 255);
      FinishSample(S, True);
      Result.Samples.Add(S);
    until False;
    if Result.Count = 0 then
      raise Exception.Create('No track points (<trkpt>) found in the GPX file.');
    DeriveMotion(Result, True, True);
    Info := Format('GPX, %d points read. Speed and heading worked out from the positions; ' +
      'GPX has no g-force data.', [Result.Count]);
  except
    Result.Free;
    raise;
  end;
end;

{ ---------------------------------------------------------------- files }

function ReadTextFile(const FileName: string): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);   // detects a UTF-8 / UTF-16 byte order mark
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function RaceBoxImportFile(const FileName: string; out Info: string): TRaceBoxSession;
begin
  Result := RaceBoxImportFile(FileName, TRaceBoxImportOptions.Default, Info);
end;

function RaceBoxImportFile(const FileName: string; const Options: TRaceBoxImportOptions;
  out Info: string): TRaceBoxSession;
var
  Ext, Text: string;
  FileDate: TDateTime;
begin
  if not FileAge(FileName, FileDate) then FileDate := Date;
  Text := ReadTextFile(FileName);
  Ext := LowerCase(ExtractFileExt(FileName));
  if Ext = '.vbo' then
    Result := RaceBoxImportVboText(Text, Options, FileDate, Info)
  else if Ext = '.gpx' then
    Result := RaceBoxImportGpxText(Text, Info)
  else
    Result := RaceBoxImportCsvText(Text, Options, FileDate, Info);
  Info := ExtractFileName(FileName) + ': ' + Info;
end;

initialization
{$IFDEF FPC}
  Inv := DefaultFormatSettings;
{$ELSE}
  Inv := TFormatSettings.Invariant;
{$ENDIF}
  Inv.DecimalSeparator := '.';
  Inv.ThousandSeparator := #0;
end.
