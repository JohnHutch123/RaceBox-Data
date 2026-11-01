program RaceBoxReader;

{ Connects to a RaceBox Mini / Mini S / Micro over Bluetooth LE, shows live
  data, downloads the recorded sessions and saves them as CSV.
  Needs Windows 10 or later with Bluetooth LE. }

uses
  Vcl.Forms,
  RaceBox.Protocol in '..\Source\RaceBox.Protocol.pas',
  RaceBox.Session in '..\Source\RaceBox.Session.pas',
  RaceBox.BLE in '..\Source\RaceBox.BLE.pas',
  RaceBoxMain in 'RaceBoxMain.pas' {FormRaceBox};

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'RaceBox Reader';
  Application.CreateForm(TFormRaceBox, FormRaceBox);
  Application.Run;
end.
