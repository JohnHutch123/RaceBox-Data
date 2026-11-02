program RaceBoxImportTest;

{ Checks RaceBox.Import against small hand-made files in the shapes RaceBox
  exports: CSV (column names vary with the preset), VBO and GPX.

  Delphi:      dcc32 -U..\Source RaceBoxImportTest.dpr
  Free Pascal: fpc -Mdelphi -Fu../Source RaceBoxImportTest.dpr }

{$APPTYPE CONSOLE}
{$IFDEF FPC}{$MODE DELPHI}{$MINFPCONSTPREC 64}{$ENDIF}

uses
{$IFDEF FPC}
  SysUtils, Classes, Math,
{$ELSE}
  System.SysUtils, System.Classes, System.Math,
{$ENDIF}
  RaceBox.Protocol, RaceBox.Session, RaceBox.Import;

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

function Ms(Y, Mo, D, H, Mi, S, Z: Word): Int64;
begin
  Result := Round((EncodeDate(Y, Mo, D) + EncodeTime(H, Mi, S, Z) - 25569) * 86400000);
end;

const
  NL = sLineBreak;

procedure TestTimes;
var
  U: Int64;
  T: Int64;
begin
  Writeln('Time parsing');
  Check('ISO with Z', RaceBoxTryParseIsoTime('2026-10-12T14:03:22.450Z', U) and (U = Ms(2026, 10, 12, 14, 3, 22, 450)));
  Check('ISO with space, no zone', RaceBoxTryParseIsoTime('2026-10-12 14:03:22', U) and (U = Ms(2026, 10, 12, 14, 3, 22, 0)));
  Check('ISO with +02:00', RaceBoxTryParseIsoTime('2026-10-12T16:03:22.5+02:00', U) and (U = Ms(2026, 10, 12, 14, 3, 22, 500)));
  Check('date only', RaceBoxTryParseIsoTime('2026-10-12', U) and (U = Ms(2026, 10, 12, 0, 0, 0, 0)));
  Check('rejects junk', not RaceBoxTryParseIsoTime('12/10/2026', U));
  Check('time of day', RaceBoxTryParseTimeOfDay('9:05:07.25', T) and (T = (9 * 3600 + 5 * 60 + 7) * 1000 + 250));
end;

procedure TestCsvComma;
const
  Csv =
    'RaceBox session export' + NL +
    'Date,2026-10-12' + NL +
    'Record,Time,Latitude,Longitude,Altitude,Speed,GForceX,GForceY,GForceZ,Lap,GyroX,GyroY,GyroZ' + NL +
    '1,2026-10-12T14:03:22.000Z,51.5678901,-1.1234567,72.4,162.0,-1.25,0.98,1.003,1,-15.2,0.35,90.01' + NL +
    '2,2026-10-12T14:03:22.040Z,51.5679001,-1.1234567,72.5,160.2,-1.20,0.97,1.001,1,-15.0,0.30,89.00' + NL +
    '3,2026-10-12T14:03:22.080Z,51.5679101,-1.1234567,72.6,158.4,-1.10,0.95,1.000,2,-14.0,0.20,88.00' + NL;
var
  S: TRaceBoxSession;
  Info: string;
  A: TRaceBoxSample;
begin
  Writeln('CSV, comma, ISO time');
  S := RaceBoxImportCsvText(Csv, TRaceBoxImportOptions.Default, Date, Info);
  try
    Writeln('         ', Info);
    Check('3 rows', S.Count = 3);
    A := S.Samples[0];
    Check('time', A.TimeValid and (A.UnixTimeMs = Ms(2026, 10, 12, 14, 3, 22, 0)));
    Check('position', Near(A.Latitude, 51.5678901) and Near(A.Longitude, -1.1234567));
    Check('speed km/h -> m/s', Near(A.Speed, 45) and Near(A.SpeedKmh, 162));
    Check('g and gyro', Near(A.GForceX, -1.25) and Near(A.GForceZ, 1.003) and Near(A.GyroZ, 90.01));
    Check('altitude', Near(A.AltitudeMSL, 72.4));
    Check('lap numbers', (S.Samples[0].Lap = 1) and (S.Samples[2].Lap = 2) and (S.LapCount = 2));
    Check('good fix', A.HasGoodFix);
    Check('heading worked out (north)', Near(S.Samples[1].Heading, 0, 0.01));
    Check('duration', Near(S.DurationSeconds, 0.08, 1e-6));
  finally
    S.Free;
  end;
end;

procedure TestCsvSemicolon;
const
  Csv =
    'Session;Silverstone' + NL +
    'Date;12.10.2026' + NL +
    'Time;Lat;Lon;Speed (mph);Heading;Sats' + NL +
    '23:59:59.900;51,1;-1,2;60;90;12' + NL;   // decimal commas are not supported: row skipped
  Csv2 =
    'Session;Silverstone' + NL +
    'Date;12.10.2026' + NL +
    'Time;Lat;Lon;Speed (mph);Heading;Sats' + NL +
    '23:59:59.900;51.1;-1.2;60;90;12' + NL +
    '00:00:00.000;51.1;-1.2;61;91;12' + NL;
var
  S: TRaceBoxSession;
  Info: string;
begin
  Writeln('CSV, semicolon, time of day, mph');
  S := RaceBoxImportCsvText(Csv2, TRaceBoxImportOptions.Default, Date, Info);
  try
    Writeln('         ', Info);
    Check('2 rows', S.Count = 2);
    Check('mph -> m/s', Near(S.Samples[0].Speed, 60 * 0.44704));
    Check('date from header', S.Samples[0].UnixTimeMs = Ms(2026, 10, 12, 23, 59, 59, 900));
    Check('midnight rollover', S.Samples[1].UnixTimeMs = Ms(2026, 10, 13, 0, 0, 0, 0));
    Check('sats and heading', (S.Samples[0].NumSV = 12) and Near(S.Samples[1].Heading, 91));
  finally
    S.Free;
  end;
  try
    S := RaceBoxImportCsvText(Csv, TRaceBoxImportOptions.Default, Date, Info);
    S.Free;
    Check('no usable rows raises', False);
  except
    on E: Exception do Check('no usable rows raises: ' + E.Message, True);
  end;
  try
    S := RaceBoxImportCsvText('a,b,c' + NL + '1,2,3', TRaceBoxImportOptions.Default, Date, Info);
    S.Free;
    Check('missing lat/lon raises', False);
  except
    on E: Exception do Check('missing lat/lon raises', True);
  end;
end;

procedure TestVbo;
const
  Vbo =
    'File created on 12/10/2026 @ 14:03:22' + NL +
    '' + NL +
    '[header]' + NL +
    'satellites' + NL + 'time' + NL + 'latitude' + NL + 'longitude' + NL +
    'velocity kmh' + NL + 'heading' + NL + 'height' + NL +
    '' + NL +
    '[column names]' + NL +
    'sats time lat long velocity heading height LatAcc LongAcc' + NL +
    '' + NL +
    '[data]' + NL +
    '011 140322.00 +03094.07341 +00067.40740 162.000 270.12 +00072.40 +0.98 -1.25' + NL +
    '011 140322.04 +03094.07347 +00067.40740 160.200 270.10 +00072.50 +0.97 -1.20' + NL;
var
  S: TRaceBoxSession;
  Info: string;
  A: TRaceBoxSample;
begin
  Writeln('VBO');
  S := RaceBoxImportVboText(Vbo, TRaceBoxImportOptions.Default, Date, Info);
  try
    Writeln('         ', Info);
    Check('2 rows', S.Count = 2);
    A := S.Samples[0];
    Check('time and date', A.UnixTimeMs = Ms(2026, 10, 12, 14, 3, 22, 0));
    Check('second row time', S.Samples[1].UnixTimeMs = Ms(2026, 10, 12, 14, 3, 22, 40));
    Check('latitude from minutes', Near(A.Latitude, 3094.07341 / 60, 1e-9));
    Check('longitude positive west', Near(A.Longitude, -67.40740 / 60, 1e-9));
    Check('speed', Near(A.SpeedKmh, 162));
    Check('heading, height, sats', Near(A.Heading, 270.12) and Near(A.AltitudeMSL, 72.4) and (A.NumSV = 11));
    Check('long/lat acc', Near(A.GForceX, -1.25) and Near(A.GForceY, 0.98));
  finally
    S.Free;
  end;
end;

procedure TestGpx;
const
  Gpx =
    '<?xml version="1.0"?>' + NL +
    '<gpx version="1.1" creator="RaceBox"><trk><trkseg>' + NL +
    '<trkpt lat="51.5000000" lon="-1.1000000"><ele>72.4</ele><time>2026-10-12T14:03:22.000Z</time></trkpt>' + NL +
    '<trkpt lat="51.5001000" lon="-1.1000000"><ele>72.5</ele><time>2026-10-12T14:03:23.000Z</time></trkpt>' + NL +
    '</trkseg></trk></gpx>';
var
  S: TRaceBoxSession;
  Info: string;
begin
  Writeln('GPX');
  S := RaceBoxImportGpxText(Gpx, Info);
  try
    Writeln('         ', Info);
    Check('2 points', S.Count = 2);
    Check('time', S.Samples[1].UnixTimeMs = Ms(2026, 10, 12, 14, 3, 23, 0));
    Check('speed from positions (~11.1 m/s)', Near(S.Samples[1].Speed, 0.0001 * 111195.08, 0.01));
    Check('heading north', Near(S.Samples[1].Heading, 0, 0.01));
  finally
    S.Free;
  end;
end;

begin
  TestTimes;
  TestCsvComma;
  TestCsvSemicolon;
  TestVbo;
  TestGpx;
  Writeln;
  if Failures = 0 then
    Writeln('All RaceBox import tests passed.')
  else
    Writeln(Failures, ' RaceBox import test(s) FAILED.');
  ExitCode := Ord(Failures > 0);
end.
