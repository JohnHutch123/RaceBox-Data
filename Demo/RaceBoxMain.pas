unit RaceBoxMain;

{ Demo form for TRaceBoxClient. The controls are created in code so the
  .dfm stays tiny and easy to merge.

  1. Scan, pick your RaceBox in the list, Connect.  Live data shows at the top right.
  2. If you set a memory security code in the RaceBox app, type it and press Unlock.
  3. Status shows how many records are stored; Download fetches them all.
  4. Save CSV writes one file per session; Save raw keeps the exact bytes,
     which Open file can decode again later (no device needed). }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.UITypes, System.Math, System.StrUtils,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Dialogs,
  RaceBox.Protocol, RaceBox.Session, RaceBox.BLE;

type
  TFormRaceBox = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FClient: TRaceBoxClient;
    FSessions: TRaceBoxSessionList;     // what the list view shows (owned)

    FTop: TPanel;
    FBtnScan, FBtnConnect, FBtnDisconnect, FBtnStatus, FBtnUnlock,
    FBtnDownload, FBtnCancel, FBtnSaveCsv, FBtnSaveRaw, FBtnOpen: TButton;
    FEditCode: TEdit;
    FDevices: TListBox;
    FLive: TMemo;
    FSessionView: TListView;
    FLog: TMemo;
    FProgress: TProgressBar;
    FStatus: TStatusBar;

    function AddButton(const ACaption: string; ALeft, ATop: Integer; AClick: TNotifyEvent): TButton;
    procedure BuildUI;
    procedure UpdateButtons;
    procedure ShowSessions(ASessions: TRaceBoxSessionList);
    function SelectedSessions: TList;

    procedure BtnScanClick(Sender: TObject);
    procedure BtnConnectClick(Sender: TObject);
    procedure BtnDisconnectClick(Sender: TObject);
    procedure BtnStatusClick(Sender: TObject);
    procedure BtnUnlockClick(Sender: TObject);
    procedure BtnDownloadClick(Sender: TObject);
    procedure BtnCancelClick(Sender: TObject);
    procedure BtnSaveCsvClick(Sender: TObject);
    procedure BtnSaveRawClick(Sender: TObject);
    procedure BtnOpenClick(Sender: TObject);

    procedure ClientDeviceFound(Sender: TObject; Index: Integer; const Name, Address: string; Rssi: Integer);
    procedure ClientScanDone(Sender: TObject);
    procedure ClientConnected(Sender: TObject);
    procedure ClientDisconnected(Sender: TObject);
    procedure ClientDeviceInfo(Sender: TObject);
    procedure ClientLiveSample(Sender: TObject; const Sample: TRaceBoxSample);
    procedure ClientRecordingStatus(Sender: TObject; const Status: TRaceBoxRecordingStatus);
    procedure ClientAck(Sender: TObject; MsgClass, MsgId: Byte; Ack: Boolean);
    procedure ClientDownloadProgress(Sender: TObject; Received, Expected: Cardinal);
    procedure ClientDownloadComplete(Sender: TObject; Cancelled: Boolean);
    procedure ClientLog(Sender: TObject; const Msg: string);
    procedure ClientError(Sender: TObject; const Msg: string);
  end;

var
  FormRaceBox: TFormRaceBox;

implementation

{$R *.dfm}

{ ---------------------------------------------------------------- UI setup }

function TFormRaceBox.AddButton(const ACaption: string; ALeft, ATop: Integer;
  AClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := FTop;
  Result.SetBounds(ALeft, ATop, 92, 28);
  Result.Caption := ACaption;
  Result.OnClick := AClick;
end;

procedure TFormRaceBox.BuildUI;
var
  Left: TPanel;
  Split: TSplitter;
  Lbl: TLabel;
  Col: TListColumn;

  procedure AddColumn(const ACaption: string; AWidth: Integer);
  begin
    Col := FSessionView.Columns.Add;
    Col.Caption := ACaption;
    Col.Width := AWidth;
  end;

begin
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := True;
  FStatus.SimpleText := 'Not connected';

  FTop := TPanel.Create(Self);
  FTop.Parent := Self;
  FTop.Align := alTop;
  FTop.Height := 80;
  FTop.BevelOuter := bvNone;

  FBtnScan       := AddButton('Scan',       8,   8, BtnScanClick);
  FBtnConnect    := AddButton('Connect',    104, 8, BtnConnectClick);
  FBtnDisconnect := AddButton('Disconnect', 200, 8, BtnDisconnectClick);
  FBtnStatus     := AddButton('Status',     312, 8, BtnStatusClick);
  FBtnDownload   := AddButton('Download',   408, 8, BtnDownloadClick);
  FBtnCancel     := AddButton('Cancel',     504, 8, BtnCancelClick);
  FBtnSaveCsv    := AddButton('Save CSV...', 616, 8, BtnSaveCsvClick);
  FBtnSaveRaw    := AddButton('Save raw...', 712, 8, BtnSaveRawClick);
  FBtnOpen       := AddButton('Open file...', 808, 8, BtnOpenClick);

  Lbl := TLabel.Create(Self);
  Lbl.Parent := FTop;
  Lbl.SetBounds(8, 50, 140, 20);
  Lbl.Caption := 'Memory security code:';
  FEditCode := TEdit.Create(Self);
  FEditCode.Parent := FTop;
  FEditCode.SetBounds(150, 46, 100, 23);
  FEditCode.NumbersOnly := True;
  FEditCode.TextHint := 'only if set';
  FBtnUnlock := AddButton('Unlock', 256, 44, BtnUnlockClick);

  FProgress := TProgressBar.Create(Self);
  FProgress.Parent := FTop;
  FProgress.SetBounds(408, 48, 488, 18);

  FLog := TMemo.Create(Self);
  FLog.Parent := Self;
  FLog.Align := alBottom;
  FLog.Height := 170;
  FLog.ReadOnly := True;
  FLog.ScrollBars := ssVertical;

  Split := TSplitter.Create(Self);
  Split.Parent := Self;
  Split.Align := alBottom;

  Left := TPanel.Create(Self);
  Left.Parent := Self;
  Left.Align := alLeft;
  Left.Width := 300;
  Left.BevelOuter := bvNone;

  FDevices := TListBox.Create(Self);
  FDevices.Parent := Left;
  FDevices.Align := alTop;
  FDevices.Height := 110;
  FDevices.OnDblClick := BtnConnectClick;

  FLive := TMemo.Create(Self);
  FLive.Parent := Left;
  FLive.Align := alClient;
  FLive.ReadOnly := True;
  FLive.Font.Name := 'Consolas';
  FLive.Lines.Text := 'Live data appears here once connected.';

  FSessionView := TListView.Create(Self);
  FSessionView.Parent := Self;
  FSessionView.Align := alClient;
  FSessionView.ViewStyle := vsReport;
  FSessionView.ReadOnly := True;
  FSessionView.RowSelect := True;
  FSessionView.MultiSelect := True;
  AddColumn('#', 40);
  AddColumn('Start (UTC)', 150);
  AddColumn('Duration', 80);
  AddColumn('Samples', 80);
  AddColumn('Distance km', 90);
  AddColumn('Max km/h', 80);
  AddColumn('Pauses', 60);
end;

procedure TFormRaceBox.FormCreate(Sender: TObject);
begin
  BuildUI;
  FSessions := TRaceBoxSessionList.Create(True);
  FClient := TRaceBoxClient.Create;
  FClient.OnDeviceFound := ClientDeviceFound;
  FClient.OnScanDone := ClientScanDone;
  FClient.OnConnected := ClientConnected;
  FClient.OnDisconnected := ClientDisconnected;
  FClient.OnDeviceInfo := ClientDeviceInfo;
  FClient.OnLiveSample := ClientLiveSample;
  FClient.OnRecordingStatus := ClientRecordingStatus;
  FClient.OnAck := ClientAck;
  FClient.OnDownloadProgress := ClientDownloadProgress;
  FClient.OnDownloadComplete := ClientDownloadComplete;
  FClient.OnLog := ClientLog;
  FClient.OnError := ClientError;
  UpdateButtons;
end;

procedure TFormRaceBox.FormDestroy(Sender: TObject);
begin
  FClient.Free;
  FSessions.Free;
end;

procedure TFormRaceBox.UpdateButtons;
var
  St: TRaceBoxClientState;
begin
  St := FClient.State;
  FBtnScan.Enabled := St = rcsIdle;
  FBtnConnect.Enabled := (St = rcsIdle) and (FDevices.ItemIndex >= 0);
  FBtnDisconnect.Enabled := St in [rcsConnecting, rcsConnected, rcsDownloading, rcsErasing];
  FBtnStatus.Enabled := St = rcsConnected;
  FBtnUnlock.Enabled := St = rcsConnected;
  FBtnDownload.Enabled := St = rcsConnected;
  FBtnCancel.Enabled := St = rcsDownloading;
  FBtnSaveCsv.Enabled := FSessions.Count > 0;
  FBtnSaveRaw.Enabled := (St <> rcsDownloading) and (FSessions.Count > 0);
end;

{ ---------------------------------------------------------------- buttons }

procedure TFormRaceBox.BtnScanClick(Sender: TObject);
begin
  FDevices.Clear;
  FClient.StartScan(8000);
  FStatus.SimpleText := 'Scanning... switch the RaceBox on and close the RaceBox phone app.';
  UpdateButtons;
end;

procedure TFormRaceBox.BtnConnectClick(Sender: TObject);
begin
  if FDevices.ItemIndex < 0 then Exit;
  FClient.Connect(Integer(NativeInt(FDevices.Items.Objects[FDevices.ItemIndex])));
  FStatus.SimpleText := 'Connecting...';
  UpdateButtons;
end;

procedure TFormRaceBox.BtnDisconnectClick(Sender: TObject);
begin
  FClient.Disconnect;
  FStatus.SimpleText := 'Not connected';
  UpdateButtons;
end;

procedure TFormRaceBox.BtnStatusClick(Sender: TObject);
begin
  FClient.RequestRecordingStatus;
end;

procedure TFormRaceBox.BtnUnlockClick(Sender: TObject);
var
  Code: Int64;
begin
  if not TryStrToInt64(FEditCode.Text, Code) or (Code < 0) or (Code > High(Cardinal)) then
  begin
    ShowMessage('Type the numeric security code you set in the RaceBox app.');
    Exit;
  end;
  FClient.Unlock(Cardinal(Code));
end;

procedure TFormRaceBox.BtnDownloadClick(Sender: TObject);
begin
  FProgress.Position := 0;
  FClient.StartDownload;
  FStatus.SimpleText := 'Downloading...';
  UpdateButtons;
end;

procedure TFormRaceBox.BtnCancelClick(Sender: TObject);
begin
  FClient.CancelDownload;
end;

function TFormRaceBox.SelectedSessions: TList;
var
  I: Integer;
begin
  Result := TList.Create;
  for I := 0 to FSessionView.Items.Count - 1 do
    if FSessionView.Items[I].Selected then
      Result.Add(FSessions[I]);
  if Result.Count = 0 then
    for I := 0 to FSessions.Count - 1 do
      Result.Add(FSessions[I]);
end;

procedure TFormRaceBox.BtnSaveCsvClick(Sender: TObject);
var
  Dlg: TFileOpenDialog;
  Pick: TList;
  Subset: TRaceBoxSessionList;
  Files: TArray<string>;
  I: Integer;
begin
  Dlg := TFileOpenDialog.Create(nil);
  try
    Dlg.Title := 'Folder for the CSV files (selected sessions, or all)';
    Dlg.Options := [fdoPickFolders, fdoPathMustExist];
    if not Dlg.Execute then Exit;
    Pick := SelectedSessions;
    Subset := TRaceBoxSessionList.Create(False);   // does not own the sessions
    try
      for I := 0 to Pick.Count - 1 do
        Subset.Add(TRaceBoxSession(Pick[I]));
      Files := RaceBoxSaveSessionsCsv(Dlg.FileName, Subset);
    finally
      Subset.Free;
      Pick.Free;
    end;
    for I := 0 to High(Files) do
      ClientLog(Self, 'Saved ' + Files[I]);
    FStatus.SimpleText := Format('Saved %d CSV file(s) to %s', [Length(Files), Dlg.FileName]);
  finally
    Dlg.Free;
  end;
end;

procedure TFormRaceBox.BtnSaveRawClick(Sender: TObject);
var
  Dlg: TSaveDialog;
begin
  Dlg := TSaveDialog.Create(nil);
  try
    Dlg.Title := 'Save the raw download (can be decoded again later)';
    Dlg.Filter := 'RaceBox raw download (*.rbx)|*.rbx|All files|*.*';
    Dlg.DefaultExt := 'rbx';
    Dlg.FileName := 'RaceBox_' + FormatDateTime('yyyymmdd_hhnnss', Now) + '.rbx';
    Dlg.Options := Dlg.Options + [ofOverwritePrompt];
    if Dlg.Execute then
    begin
      FClient.SaveRawDump(Dlg.FileName);
      ClientLog(Self, 'Saved raw download to ' + Dlg.FileName);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TFormRaceBox.BtnOpenClick(Sender: TObject);
var
  Dlg: TOpenDialog;
  L: TRaceBoxSessionList;
  Session: TRaceBoxSession;
  Samples: TRaceBoxSampleList;
begin
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Filter := 'RaceBox raw download or CSV (*.rbx;*.csv)|*.rbx;*.csv|All files|*.*';
    if not Dlg.Execute then Exit;
    if SameText(ExtractFileExt(Dlg.FileName), '.csv') then
    begin
      Samples := RaceBoxLoadCsv(Dlg.FileName);
      try
        L := TRaceBoxSessionList.Create(True);
        Session := TRaceBoxSession.Create;
        Session.Samples.AddRange(Samples);
        L.Add(Session);
      finally
        Samples.Free;
      end;
    end
    else
      L := RaceBoxLoadDumpFile(Dlg.FileName, FClient.MaxGapSeconds);
    ShowSessions(L);
    ClientLog(Self, Format('Opened %s: %d session(s).', [Dlg.FileName, L.Count]));
  finally
    Dlg.Free;
  end;
end;

procedure TFormRaceBox.ShowSessions(ASessions: TRaceBoxSessionList);
var
  I, D: Integer;
  S: TRaceBoxSession;
  Item: TListItem;
begin
  FSessions.Free;
  FSessions := ASessions;
  FSessionView.Items.BeginUpdate;
  try
    FSessionView.Items.Clear;
    for I := 0 to FSessions.Count - 1 do
    begin
      S := FSessions[I];
      D := Round(S.DurationSeconds);
      Item := FSessionView.Items.Add;
      Item.Caption := IntToStr(I + 1);
      if S.StartTime = 0 then
        Item.SubItems.Add('(no GPS time)')
      else
        Item.SubItems.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss', S.StartTime));
      Item.SubItems.Add(Format('%d:%.2d:%.2d', [D div 3600, (D div 60) mod 60, D mod 60]));
      Item.SubItems.Add(IntToStr(S.Count));
      Item.SubItems.Add(FormatFloat('0.00', S.DistanceMeters / 1000));
      Item.SubItems.Add(FormatFloat('0', S.MaxSpeedKmh));
      Item.SubItems.Add(IntToStr(S.PauseCount));
    end;
  finally
    FSessionView.Items.EndUpdate;
  end;
  UpdateButtons;
end;

{ ---------------------------------------------------------------- client events }

procedure TFormRaceBox.ClientDeviceFound(Sender: TObject; Index: Integer;
  const Name, Address: string; Rssi: Integer);
begin
  FDevices.Items.AddObject(Format('%s  (%d dBm)', [Name, Rssi]), TObject(NativeInt(Index)));
  if FDevices.ItemIndex < 0 then
    FDevices.ItemIndex := 0;
  UpdateButtons;
end;

procedure TFormRaceBox.ClientScanDone(Sender: TObject);
begin
  if FDevices.Count = 0 then
    FStatus.SimpleText := 'No RaceBox found. Is it on, and not connected to the phone app?'
  else
    FStatus.SimpleText := 'Pick a device and press Connect.';
  UpdateButtons;
end;

procedure TFormRaceBox.ClientConnected(Sender: TObject);
begin
  FStatus.SimpleText := 'Connected to ' + FClient.DeviceName;
  UpdateButtons;
  FClient.RequestRecordingStatus;
end;

procedure TFormRaceBox.ClientDisconnected(Sender: TObject);
begin
  FStatus.SimpleText := 'Not connected';
  UpdateButtons;
end;

procedure TFormRaceBox.ClientDeviceInfo(Sender: TObject);
begin
  FStatus.SimpleText := Format('Connected to %s   model %s   serial %s   firmware %s',
    [FClient.DeviceName, FClient.Model, FClient.SerialNumber, FClient.FirmwareVersion]);
end;

procedure TFormRaceBox.ClientLiveSample(Sender: TObject; const Sample: TRaceBoxSample);
const
  FixName: array[0..3] of string = ('none', '?', '2D', '3D');
begin
  // 25 Hz is more than a memo needs; show about 5 updates a second.
  if FClient.LiveSampleCount mod 5 <> 0 then Exit;
  FLive.Lines.BeginUpdate;
  try
    FLive.Lines.Clear;
    if Sample.TimeValid then
      FLive.Lines.Add('UTC      ' + FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Sample.UtcTime))
    else
      FLive.Lines.Add('UTC      (waiting for GPS time)');
    FLive.Lines.Add(Format('Fix      %s, %d sats%s', [FixName[Min(Sample.FixStatus, 3)], Sample.NumSV,
      IfThen(Sample.HasGoodFix, '', '  (not usable yet)')]));
    FLive.Lines.Add(Format('Lat      %.7f', [Sample.Latitude]));
    FLive.Lines.Add(Format('Lon      %.7f', [Sample.Longitude]));
    FLive.Lines.Add(Format('Alt      %.1f m', [Sample.AltitudeMSL]));
    FLive.Lines.Add(Format('Speed    %.1f km/h', [Sample.SpeedKmh]));
    FLive.Lines.Add(Format('Heading  %.1f deg', [Sample.Heading]));
    FLive.Lines.Add(Format('G        X %.2f  Y %.2f  Z %.2f', [Sample.GForceX, Sample.GForceY, Sample.GForceZ]));
    FLive.Lines.Add(Format('Gyro     X %.1f  Y %.1f  Z %.1f deg/s', [Sample.GyroX, Sample.GyroY, Sample.GyroZ]));
    FLive.Lines.Add(Format('Battery  %d %%%s', [Sample.BatteryPercent, IfThen(Sample.IsCharging, ' (charging)', '')]));
  finally
    FLive.Lines.EndUpdate;
  end;
end;

procedure TFormRaceBox.ClientRecordingStatus(Sender: TObject; const Status: TRaceBoxRecordingStatus);
begin
  ClientLog(Self, Format('Recording: %s.  Memory %d %% used, %d of %d records.  Security: %s.',
    [IfThen(Status.Recording, 'ON', 'off'), Status.MemoryLevel, Status.StoredMessages, Status.MemorySize,
     IfThen(not Status.SecurityEnabled, 'off', IfThen(Status.Unlocked, 'unlocked', 'LOCKED - enter code and press Unlock'))]));
end;

procedure TFormRaceBox.ClientAck(Sender: TObject; MsgClass, MsgId: Byte; Ack: Boolean);
begin
  if (MsgId = RB_ID_UNLOCK) then
    if Ack then
      FStatus.SimpleText := 'Memory unlocked.'
    else
      FStatus.SimpleText := 'Wrong security code.';
end;

procedure TFormRaceBox.ClientDownloadProgress(Sender: TObject; Received, Expected: Cardinal);
begin
  FProgress.Max := Max(1, Integer(Expected));
  FProgress.Position := Min(Integer(Received), FProgress.Max);
  FStatus.SimpleText := Format('Downloading... %d of up to %d records', [Received, Expected]);
end;

procedure TFormRaceBox.ClientDownloadComplete(Sender: TObject; Cancelled: Boolean);
begin
  ShowSessions(FClient.ExtractSessions);
  FStatus.SimpleText := Format('Download %s: %d session(s). Select rows and press Save CSV.',
    [IfThen(Cancelled, 'cancelled', 'finished'), FSessions.Count]);
  UpdateButtons;
end;

procedure TFormRaceBox.ClientLog(Sender: TObject; const Msg: string);
begin
  FLog.Lines.Add(FormatDateTime('hh:nn:ss  ', Now) + Msg);
end;

procedure TFormRaceBox.ClientError(Sender: TObject; const Msg: string);
begin
  ClientLog(Sender, 'ERROR: ' + Msg);
  FStatus.SimpleText := Msg;
  UpdateButtons;
end;

end.
