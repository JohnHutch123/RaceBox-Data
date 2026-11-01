unit RaceBox.BLE;

{ Connects to a RaceBox Mini / Mini S / Micro over Bluetooth LE with Delphi's
  own System.Bluetooth classes (Windows 10 or later, no extra libraries),
  streams live data and downloads the sessions stored on the device.

  Typical use:
    Client := TRaceBoxClient.Create;
    Client.OnDeviceFound := ...;   Client.StartScan;
    Client.Connect(0);             // index into the found devices
    Client.OnLiveSample := ...;    // 25 Hz live data starts by itself
    Client.Unlock(Code);           // only if memory security is enabled
    Client.StartDownload;          // OnDownloadComplete -> Client.Sessions

  All events are raised on the main thread (set SyncEvents := False to get
  them on the Bluetooth thread instead).

  RaceBox-Data, zlib licence (see LICENSE). }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  System.Bluetooth, RaceBox.Protocol, RaceBox.Session;

type
  TRaceBoxClientState = (rcsIdle, rcsScanning, rcsConnecting, rcsConnected,
    rcsDownloading, rcsErasing);

  TRaceBoxDeviceFoundEvent = procedure(Sender: TObject; Index: Integer;
    const Name, Address: string; Rssi: Integer) of object;
  TRaceBoxSampleEvent = procedure(Sender: TObject; const Sample: TRaceBoxSample) of object;
  TRaceBoxStatusEvent = procedure(Sender: TObject; const Status: TRaceBoxRecordingStatus) of object;
  TRaceBoxConfigEvent = procedure(Sender: TObject; const Config: TRaceBoxRecordingConfig) of object;
  TRaceBoxGnssEvent = procedure(Sender: TObject; const Config: TRaceBoxGnssConfig) of object;
  TRaceBoxStateChangeEvent = procedure(Sender: TObject; const Change: TRaceBoxStateChange) of object;
  TRaceBoxAckEvent = procedure(Sender: TObject; MsgClass, MsgId: Byte; Ack: Boolean) of object;
  TRaceBoxProgressEvent = procedure(Sender: TObject; Received, Expected: Cardinal) of object;
  TRaceBoxPercentEvent = procedure(Sender: TObject; Percent: Integer) of object;
  TRaceBoxDownloadDoneEvent = procedure(Sender: TObject; Cancelled: Boolean) of object;
  TRaceBoxLogEvent = procedure(Sender: TObject; const Msg: string) of object;

  { Lets queued events find out the client was freed before they ran. }
  IRaceBoxAlive = interface
    ['{8C1E6E2B-7F51-4E0A-9D37-0E5C2E9A41B7}']
    function IsAlive: Boolean;
    procedure Kill;
  end;

  TRaceBoxClient = class
  private
    FManager: TBluetoothLEManager;
    FDevices: TList<TBluetoothLEDevice>;   // owned by the manager
    FDevice: TBluetoothLEDevice;
    FUartService: TBluetoothGattService;
    FRxChar: TBluetoothGattCharacteristic;
    FTxChar: TBluetoothGattCharacteristic;
    FLock: TCriticalSection;
    FParser: TRaceBoxPacketParser;
    FSplitter: TRaceBoxSessionSplitter;
    FSessions: TRaceBoxSessionList;
    FRawDump: TMemoryStream;
    FAlive: IRaceBoxAlive;
    FState: TRaceBoxClientState;
    FSyncEvents: Boolean;
    FNameFilter: string;
    FMaxGapSeconds: Double;
    FDownloadExpected: Cardinal;
    FDownloadReceived: Cardinal;
    FDownloadCancelled: Boolean;
    FLastProgressTick: UInt64;
    FLiveSampleCount: Int64;
    FLastLive: TRaceBoxSample;
    FModel, FSerial, FFirmware, FHardware: string;
    FUartUUID, FRxUUID, FTxUUID: TBluetoothUUID;

    FOnDeviceFound: TRaceBoxDeviceFoundEvent;
    FOnScanDone: TNotifyEvent;
    FOnConnected: TNotifyEvent;
    FOnDisconnected: TNotifyEvent;
    FOnDeviceInfo: TNotifyEvent;
    FOnLiveSample: TRaceBoxSampleEvent;
    FOnRecordingStatus: TRaceBoxStatusEvent;
    FOnRecordingConfig: TRaceBoxConfigEvent;
    FOnGnssConfig: TRaceBoxGnssEvent;
    FOnStateChange: TRaceBoxStateChangeEvent;
    FOnAck: TRaceBoxAckEvent;
    FOnDownloadProgress: TRaceBoxProgressEvent;
    FOnDownloadComplete: TRaceBoxDownloadDoneEvent;
    FOnEraseProgress: TRaceBoxPercentEvent;
    FOnEraseComplete: TNotifyEvent;
    FOnLog: TRaceBoxLogEvent;
    FOnError: TRaceBoxLogEvent;

    procedure Post(const Proc: TProc);
    procedure Log(const Msg: string);
    procedure Error(const Msg: string);
    procedure SetState(Value: TRaceBoxClientState);
    function SendCommand(const Packet: TBytes; const What: string): Boolean;
    procedure RequireConnected;
    procedure ProcessPacket(const P: TRaceBoxPacket);
    procedure FinishDownload;
    procedure ReadDeviceInfo;

    procedure DoDiscoverDevice(const Sender: TObject; const ADevice: TBluetoothLEDevice;
      Rssi: Integer; const ScanResponse: TScanResponse);
    procedure DoDiscoveryEnd(const Sender: TObject; const ADeviceList: TBluetoothLEDeviceList);
    procedure DoServicesDiscovered(const Sender: TObject; const AServiceList: TBluetoothGattServiceList);
    procedure DoCharacteristicRead(const Sender: TObject;
      const ACharacteristic: TBluetoothGattCharacteristic; AGattStatus: TBluetoothGattStatus);
    function GetConnected: Boolean;
    function GetDeviceName: string;
  public
    constructor Create;
    destructor Destroy; override;

    { Scanning: devices whose name starts with NameFilter ('RaceBox') }
    procedure StartScan(TimeoutMs: Cardinal = 8000);
    procedure StopScan;
    function DeviceCount: Integer;
    function DeviceNameAt(Index: Integer): string;

    { Connection }
    procedure Connect(Index: Integer); overload;
    procedure Connect(Device: TBluetoothLEDevice); overload;
    procedure Disconnect;

    { Commands. Replies arrive as events. }
    procedure RequestRecordingStatus;
    procedure Unlock(SecurityCode: Cardinal);
    procedure StartDownload;
    procedure CancelDownload;
    procedure ReadRecordingConfig;
    procedure WriteRecordingConfig(const Config: TRaceBoxRecordingConfig);
    procedure StartRecording; overload;                 // TRaceBoxRecordingConfig.Default
    procedure StartRecording(const Config: TRaceBoxRecordingConfig); overload;
    procedure StopRecording;
    procedure ReadGnssConfig;
    procedure WriteGnssConfig(const Config: TRaceBoxGnssConfig);
    { Deletes every recording on the device. Cannot be undone. }
    procedure EraseMemory;
    procedure CancelErase;

    { Raw bytes received during the last download; RaceBoxLoadDumpFile can
      decode the file again later, so keep it as a backup of the data. }
    procedure SaveRawDump(const FileName: string);
    { Hands over the downloaded sessions (caller frees them). }
    function ExtractSessions: TRaceBoxSessionList;

    property State: TRaceBoxClientState read FState;
    property Connected: Boolean read GetConnected;
    property DeviceName: string read GetDeviceName;
    property Model: string read FModel;
    property SerialNumber: string read FSerial;
    property FirmwareVersion: string read FFirmware;
    property HardwareVersion: string read FHardware;
    property LastLiveSample: TRaceBoxSample read FLastLive;
    property LiveSampleCount: Int64 read FLiveSampleCount;
    { Downloaded sessions. Valid after OnDownloadComplete until the next download. }
    property Sessions: TRaceBoxSessionList read FSessions;
    property SyncEvents: Boolean read FSyncEvents write FSyncEvents;
    property NameFilter: string read FNameFilter write FNameFilter;
    { Split sessions when samples are further apart than this (0 = only on start/stop). }
    property MaxGapSeconds: Double read FMaxGapSeconds write FMaxGapSeconds;

    property OnDeviceFound: TRaceBoxDeviceFoundEvent read FOnDeviceFound write FOnDeviceFound;
    property OnScanDone: TNotifyEvent read FOnScanDone write FOnScanDone;
    property OnConnected: TNotifyEvent read FOnConnected write FOnConnected;
    property OnDisconnected: TNotifyEvent read FOnDisconnected write FOnDisconnected;
    property OnDeviceInfo: TNotifyEvent read FOnDeviceInfo write FOnDeviceInfo;
    property OnLiveSample: TRaceBoxSampleEvent read FOnLiveSample write FOnLiveSample;
    property OnRecordingStatus: TRaceBoxStatusEvent read FOnRecordingStatus write FOnRecordingStatus;
    property OnRecordingConfig: TRaceBoxConfigEvent read FOnRecordingConfig write FOnRecordingConfig;
    property OnGnssConfig: TRaceBoxGnssEvent read FOnGnssConfig write FOnGnssConfig;
    property OnStateChange: TRaceBoxStateChangeEvent read FOnStateChange write FOnStateChange;
    property OnAck: TRaceBoxAckEvent read FOnAck write FOnAck;
    property OnDownloadProgress: TRaceBoxProgressEvent read FOnDownloadProgress write FOnDownloadProgress;
    property OnDownloadComplete: TRaceBoxDownloadDoneEvent read FOnDownloadComplete write FOnDownloadComplete;
    property OnEraseProgress: TRaceBoxPercentEvent read FOnEraseProgress write FOnEraseProgress;
    property OnEraseComplete: TNotifyEvent read FOnEraseComplete write FOnEraseComplete;
    property OnLog: TRaceBoxLogEvent read FOnLog write FOnLog;
    property OnError: TRaceBoxLogEvent read FOnError write FOnError;
  end;

implementation

uses
  System.StrUtils;

type
  TRaceBoxAlive = class(TInterfacedObject, IRaceBoxAlive)
  private
    FAlive: Boolean;
  public
    constructor Create;
    function IsAlive: Boolean;
    procedure Kill;
  end;

constructor TRaceBoxAlive.Create;
begin
  inherited Create;
  FAlive := True;
end;

function TRaceBoxAlive.IsAlive: Boolean;
begin
  Result := FAlive;
end;

procedure TRaceBoxAlive.Kill;
begin
  FAlive := False;
end;

{ ---------------------------------------------------------------- client }

constructor TRaceBoxClient.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FParser := TRaceBoxPacketParser.Create;
  FDevices := TList<TBluetoothLEDevice>.Create;
  FSessions := TRaceBoxSessionList.Create(True);
  FRawDump := TMemoryStream.Create;
  FAlive := TRaceBoxAlive.Create;
  FSyncEvents := True;
  FNameFilter := 'RaceBox';
  FMaxGapSeconds := 300;
  FUartUUID := StringToGUID(RB_UUID_UART_SERVICE);
  FRxUUID := StringToGUID(RB_UUID_UART_RX);
  FTxUUID := StringToGUID(RB_UUID_UART_TX);
end;

destructor TRaceBoxClient.Destroy;
begin
  FAlive.Kill;               // queued events for this client now do nothing
  try
    Disconnect;
  except
    // never raise from a destructor
  end;
  if FManager <> nil then
  begin
    FManager.OnDiscoverLEDevice := nil;
    FManager.OnDiscoveryEnd := nil;
  end;
  FLock.Enter;
  try
    FreeAndNil(FSplitter);
  finally
    FLock.Leave;
  end;
  FRawDump.Free;
  FSessions.Free;
  FDevices.Free;
  FParser.Free;
  FLock.Free;
  inherited;
end;

procedure TRaceBoxClient.Post(const Proc: TProc);
var
  Alive: IRaceBoxAlive;
begin
  if not FSyncEvents then
  begin
    Proc();
    Exit;
  end;
  Alive := FAlive;
  TThread.Queue(nil,
    procedure
    begin
      if Alive.IsAlive then
        Proc();
    end);
end;

procedure TRaceBoxClient.Log(const Msg: string);
begin
  Post(
    procedure
    begin
      if Assigned(FOnLog) then FOnLog(Self, Msg);
    end);
end;

procedure TRaceBoxClient.Error(const Msg: string);
begin
  Post(
    procedure
    begin
      if Assigned(FOnError) then FOnError(Self, Msg)
      else if Assigned(FOnLog) then FOnLog(Self, 'Error: ' + Msg);
    end);
end;

procedure TRaceBoxClient.SetState(Value: TRaceBoxClientState);
begin
  FState := Value;
end;

function TRaceBoxClient.GetConnected: Boolean;
begin
  Result := (FDevice <> nil) and (FRxChar <> nil) and (FTxChar <> nil) and
    (FState in [rcsConnected, rcsDownloading, rcsErasing]);
end;

function TRaceBoxClient.GetDeviceName: string;
begin
  if FDevice <> nil then Result := FDevice.DeviceName else Result := '';
end;

{ ---------------------------------------------------------------- scanning }

procedure TRaceBoxClient.StartScan(TimeoutMs: Cardinal);
begin
  if FManager = nil then
  begin
    FManager := TBluetoothLEManager.Current;
    if FManager = nil then
      raise Exception.Create('Bluetooth LE is not available on this PC.');
  end;
  FManager.OnDiscoverLEDevice := DoDiscoverDevice;
  FManager.OnDiscoveryEnd := DoDiscoveryEnd;
  FDevices.Clear;
  SetState(rcsScanning);
  Log('Scanning for RaceBox devices...');
  if not FManager.StartDiscovery(TimeoutMs) then
  begin
    SetState(rcsIdle);
    raise Exception.Create('Could not start the Bluetooth scan. Is Bluetooth turned on?');
  end;
end;

procedure TRaceBoxClient.StopScan;
begin
  if (FManager <> nil) and (FState = rcsScanning) then
    FManager.CancelDiscovery;
end;

procedure TRaceBoxClient.DoDiscoverDevice(const Sender: TObject; const ADevice: TBluetoothLEDevice;
  Rssi: Integer; const ScanResponse: TScanResponse);
var
  Name, Addr: string;
  Index: Integer;
begin
  if ADevice = nil then Exit;
  Name := ADevice.DeviceName;
  // The name can be empty in the first advertisement; it comes again later.
  if Name = '' then Exit;
  if (FNameFilter <> '') and not Name.StartsWith(FNameFilter, True) then Exit;
  FLock.Enter;
  try
    if FDevices.IndexOf(ADevice) >= 0 then Exit;
    Index := FDevices.Add(ADevice);
  finally
    FLock.Leave;
  end;
  Addr := ADevice.Address;
  Post(
    procedure
    begin
      if Assigned(FOnDeviceFound) then FOnDeviceFound(Self, Index, Name, Addr, Rssi);
    end);
end;

procedure TRaceBoxClient.DoDiscoveryEnd(const Sender: TObject; const ADeviceList: TBluetoothLEDeviceList);
begin
  Post(
    procedure
    begin
      if FState = rcsScanning then SetState(rcsIdle);
      Log(Format('Scan finished, %d RaceBox device(s) found.', [FDevices.Count]));
      if Assigned(FOnScanDone) then FOnScanDone(Self);
    end);
end;

function TRaceBoxClient.DeviceCount: Integer;
begin
  Result := FDevices.Count;
end;

function TRaceBoxClient.DeviceNameAt(Index: Integer): string;
begin
  Result := FDevices[Index].DeviceName;
end;

{ ---------------------------------------------------------------- connection }

procedure TRaceBoxClient.Connect(Index: Integer);
begin
  if (Index < 0) or (Index >= FDevices.Count) then
    raise EArgumentOutOfRangeException.Create('No RaceBox device at that index. Scan first.');
  Connect(FDevices[Index]);
end;

procedure TRaceBoxClient.Connect(Device: TBluetoothLEDevice);
begin
  if Device = nil then
    raise EArgumentNilException.Create('Device is nil');
  if FDevice <> nil then
    Disconnect;
  StopScan;
  FDevice := Device;
  FRxChar := nil;
  FTxChar := nil;
  FUartService := nil;
  FModel := '';
  FSerial := '';
  FFirmware := '';
  FHardware := '';
  FLock.Enter;
  try
    FParser.Reset;
  finally
    FLock.Leave;
  end;
  FDevice.OnServicesDiscovered := DoServicesDiscovered;
  FDevice.OnCharacteristicRead := DoCharacteristicRead;
  SetState(rcsConnecting);
  Log('Connecting to ' + FDevice.DeviceName + '...');
  // On Windows, discovering the services opens the GATT connection.
  if not FDevice.DiscoverServices then
  begin
    SetState(rcsIdle);
    FDevice := nil;
    raise Exception.Create('Could not connect to the RaceBox (service discovery failed). ' +
      'Make sure it is switched on, close the RaceBox phone app, and try again.');
  end;
end;

procedure TRaceBoxClient.DoServicesDiscovered(const Sender: TObject;
  const AServiceList: TBluetoothGattServiceList);
var
  Device: TBluetoothLEDevice;
begin
  Device := FDevice;
  if (Device = nil) or (FTxChar <> nil) then Exit;   // already set up
  FUartService := Device.GetService(FUartUUID);
  if FUartService = nil then
  begin
    SetState(rcsIdle);
    Error('This device has no RaceBox UART service.');
    Exit;
  end;
  FRxChar := FUartService.GetCharacteristic(FRxUUID);
  FTxChar := FUartService.GetCharacteristic(FTxUUID);
  if (FRxChar = nil) or (FTxChar = nil) then
  begin
    SetState(rcsIdle);
    Error('RaceBox UART characteristics not found.');
    Exit;
  end;
  // Data arrives as notifications on TX, reported through OnCharacteristicRead.
  if not Device.SetCharacteristicNotification(FTxChar, True) then
  begin
    SetState(rcsIdle);
    Error('Could not subscribe to RaceBox notifications.');
    Exit;
  end;
  SetState(rcsConnected);
  Log('Connected to ' + Device.DeviceName + '.');
  Post(
    procedure
    begin
      if Assigned(FOnConnected) then FOnConnected(Self);
    end);
  ReadDeviceInfo;
end;

procedure TRaceBoxClient.ReadDeviceInfo;
const
  Ids: array[0..3] of string = (RB_UUID_DEVINFO_MODEL, RB_UUID_DEVINFO_SERIAL,
    RB_UUID_DEVINFO_FIRMWARE, RB_UUID_DEVINFO_HARDWARE);
var
  Svc: TBluetoothGattService;
  Ch: TBluetoothGattCharacteristic;
  I: Integer;
begin
  if FDevice = nil then Exit;
  Svc := FDevice.GetService(StringToGUID(RB_UUID_DEVINFO_SERVICE));
  if Svc = nil then Exit;
  for I := Low(Ids) to High(Ids) do
  begin
    Ch := Svc.GetCharacteristic(StringToGUID(Ids[I]));
    if Ch <> nil then
      FDevice.ReadCharacteristic(Ch);   // answer arrives in DoCharacteristicRead
  end;
end;

procedure TRaceBoxClient.Disconnect;
var
  Device: TBluetoothLEDevice;
  WasConnected: Boolean;
begin
  Device := FDevice;
  if Device = nil then Exit;
  WasConnected := FState in [rcsConnected, rcsDownloading, rcsErasing];
  try
    if FTxChar <> nil then
      Device.SetCharacteristicNotification(FTxChar, False);
  except
    // the link may already be gone
  end;
  Device.OnServicesDiscovered := nil;
  Device.OnCharacteristicRead := nil;
  try
    Device.Disconnect;
  except
  end;
  FDevice := nil;
  FRxChar := nil;
  FTxChar := nil;
  FUartService := nil;
  SetState(rcsIdle);
  Log('Disconnected.');
  if WasConnected then
    Post(
      procedure
      begin
        if Assigned(FOnDisconnected) then FOnDisconnected(Self);
      end);
end;

{ ---------------------------------------------------------------- incoming data }

procedure TRaceBoxClient.DoCharacteristicRead(const Sender: TObject;
  const ACharacteristic: TBluetoothGattCharacteristic; AGattStatus: TBluetoothGattStatus);
var
  Data: TBytes;
  P: TRaceBoxPacket;
  Text: string;
  UUID: TBluetoothUUID;
begin
  if (ACharacteristic = nil) or (AGattStatus <> TBluetoothGattStatus.Success) then Exit;
  UUID := ACharacteristic.UUID;
  Data := ACharacteristic.Value;

  if UUID <> FTxUUID then
  begin
    // Device Information strings
    Text := Trim(TEncoding.UTF8.GetString(Data));
    if UUID = StringToGUID(RB_UUID_DEVINFO_MODEL) then FModel := Text
    else if UUID = StringToGUID(RB_UUID_DEVINFO_SERIAL) then FSerial := Text
    else if UUID = StringToGUID(RB_UUID_DEVINFO_FIRMWARE) then FFirmware := Text
    else if UUID = StringToGUID(RB_UUID_DEVINFO_HARDWARE) then FHardware := Text
    else Exit;
    Post(
      procedure
      begin
        if Assigned(FOnDeviceInfo) then FOnDeviceInfo(Self);
      end);
    Exit;
  end;

  if Length(Data) = 0 then Exit;
  FLock.Enter;
  try
    if FState = rcsDownloading then
      FRawDump.WriteBuffer(Data[0], Length(Data));
    FParser.Feed(Data);
    while FParser.Next(P) do
      ProcessPacket(P);
  finally
    FLock.Leave;
  end;
end;

{ Called with FLock held, on the Bluetooth thread. }
procedure TRaceBoxClient.ProcessPacket(const P: TRaceBoxPacket);
var
  Sample: TRaceBoxSample;
  Status: TRaceBoxRecordingStatus;
  Config: TRaceBoxRecordingConfig;
  Gnss: TRaceBoxGnssConfig;
  Change: TRaceBoxStateChange;
  AckClass, AckId: Byte;
  IsAck: Boolean;
  Count: Cardinal;
  Tick: UInt64;
  Received, Expected: Cardinal;
  Percent: Integer;
begin
  if P.MsgClass <> RB_CLASS then Exit;
  case P.MsgId of
    RB_ID_DATA:
      if RaceBoxDecodeSample(P.Payload, rssLive, Sample) then
      begin
        FLastLive := Sample;
        Inc(FLiveSampleCount);
        Post(
          procedure
          begin
            if Assigned(FOnLiveSample) then FOnLiveSample(Self, Sample);
          end);
      end;

    RB_ID_HISTORY:
      if (FState = rcsDownloading) and (FSplitter <> nil) and
         RaceBoxDecodeSample(P.Payload, rssHistory, Sample) then
      begin
        FSplitter.AddSample(Sample);
        Inc(FDownloadReceived);
        Tick := TThread.GetTickCount64;
        if Tick - FLastProgressTick >= 200 then
        begin
          FLastProgressTick := Tick;
          Received := FDownloadReceived;
          Expected := FDownloadExpected;
          Post(
            procedure
            begin
              if Assigned(FOnDownloadProgress) then FOnDownloadProgress(Self, Received, Expected);
            end);
        end;
      end;

    RB_ID_STATE_CHANGE:
      if RaceBoxDecodeStateChange(P.Payload, Change) then
      begin
        if (FState = rcsDownloading) and (FSplitter <> nil) then
          FSplitter.AddStateChange(Change)
        else
          Post(
            procedure
            begin
              if Assigned(FOnStateChange) then FOnStateChange(Self, Change);
            end);
      end;

    RB_ID_REC_STATUS:
      if RaceBoxDecodeRecordingStatus(P.Payload, Status) then
        Post(
          procedure
          begin
            if Assigned(FOnRecordingStatus) then FOnRecordingStatus(Self, Status);
          end);

    RB_ID_REC_CONFIG:
      if RaceBoxDecodeRecordingConfig(P.Payload, Config) then
        Post(
          procedure
          begin
            if Assigned(FOnRecordingConfig) then FOnRecordingConfig(Self, Config);
          end);

    RB_ID_GNSS_CONFIG:
      if RaceBoxDecodeGnssConfig(P.Payload, Gnss) then
        Post(
          procedure
          begin
            if Assigned(FOnGnssConfig) then FOnGnssConfig(Self, Gnss);
          end);

    RB_ID_DOWNLOAD:
      // Reply to the start command: the most messages to expect.
      if RaceBoxDecodeU32(P.Payload, Count) then
      begin
        FDownloadExpected := Count;
        Log(Format('Download started, up to %d records.', [Count]));
        Received := 0;
        Post(
          procedure
          begin
            if Assigned(FOnDownloadProgress) then FOnDownloadProgress(Self, Received, Count);
          end);
      end;

    RB_ID_ERASE:
      if Length(P.Payload) = 1 then
      begin
        Percent := P.Payload[0];
        Post(
          procedure
          begin
            if Assigned(FOnEraseProgress) then FOnEraseProgress(Self, Percent);
          end);
      end;

    RB_ID_ACK, RB_ID_NACK:
      if RaceBoxDecodeAck(P.Payload, AckClass, AckId) then
      begin
        IsAck := P.MsgId = RB_ID_ACK;
        if (AckClass = RB_CLASS) and (AckId = RB_ID_DOWNLOAD) and (FState = rcsDownloading) then
        begin
          if IsAck then
            FinishDownload
          else
          begin
            SetState(rcsConnected);
            FreeAndNil(FSplitter);
            Error('The RaceBox refused the download. If memory security is on, unlock it first; ' +
              'otherwise another download or erase may be running.');
          end;
        end
        else if (AckClass = RB_CLASS) and (AckId = RB_ID_ERASE) and (FState = rcsErasing) then
        begin
          SetState(rcsConnected);
          if IsAck then
            Post(
              procedure
              begin
                if Assigned(FOnEraseComplete) then FOnEraseComplete(Self);
              end)
          else
            Error('The RaceBox refused to erase its memory (locked, or busy).');
        end
        else if not IsAck then
          Log('NACK for ' + RaceBoxMessageName(AckClass, AckId) + '.')
        else
          Log('ACK for ' + RaceBoxMessageName(AckClass, AckId) + '.');
        Post(
          procedure
          begin
            if Assigned(FOnAck) then FOnAck(Self, AckClass, AckId, IsAck);
          end);
      end;
  end;
end;

{ Called with FLock held. }
procedure TRaceBoxClient.FinishDownload;
var
  NewSessions: TRaceBoxSessionList;
  Cancelled: Boolean;
  Received: Cardinal;
begin
  NewSessions := FSplitter.ExtractSessions;
  FreeAndNil(FSplitter);
  Cancelled := FDownloadCancelled;
  Received := FDownloadReceived;
  SetState(rcsConnected);
  Post(
    procedure
    begin
      FSessions.Free;
      FSessions := NewSessions;
      Log(Format('Download %s: %d records in %d session(s).',
        [IfThen(Cancelled, 'cancelled', 'finished'), Received, NewSessions.Count]));
      if Assigned(FOnDownloadProgress) then FOnDownloadProgress(Self, Received, Received);
      if Assigned(FOnDownloadComplete) then FOnDownloadComplete(Self, Cancelled);
    end);
end;

{ ---------------------------------------------------------------- commands }

procedure TRaceBoxClient.RequireConnected;
begin
  if not Connected then
    raise Exception.Create('Not connected to a RaceBox.');
end;

function TRaceBoxClient.SendCommand(const Packet: TBytes; const What: string): Boolean;
begin
  RequireConnected;
  FRxChar.SetValue(Packet);
  Result := FDevice.WriteCharacteristic(FRxChar);
  if Result then
    Log('Sent: ' + What)
  else
    Error('Could not send "' + What + '" to the RaceBox.');
end;

procedure TRaceBoxClient.RequestRecordingStatus;
begin
  SendCommand(RaceBoxCmdRecordingStatus, 'recording status request');
end;

procedure TRaceBoxClient.Unlock(SecurityCode: Cardinal);
begin
  SendCommand(RaceBoxCmdUnlock(SecurityCode), 'unlock memory');
end;

procedure TRaceBoxClient.StartDownload;
begin
  RequireConnected;
  if FState = rcsDownloading then Exit;
  FLock.Enter;
  try
    FreeAndNil(FSplitter);
    FSplitter := TRaceBoxSessionSplitter.Create(FMaxGapSeconds);
    FRawDump.Clear;
    FDownloadExpected := 0;
    FDownloadReceived := 0;
    FDownloadCancelled := False;
    FLastProgressTick := 0;
    SetState(rcsDownloading);
  finally
    FLock.Leave;
  end;
  if not SendCommand(RaceBoxCmdStartDownload, 'start download') then
  begin
    FLock.Enter;
    try
      FreeAndNil(FSplitter);
      SetState(rcsConnected);
    finally
      FLock.Leave;
    end;
  end;
end;

procedure TRaceBoxClient.CancelDownload;
begin
  if FState <> rcsDownloading then Exit;
  FDownloadCancelled := True;
  // The device answers with an ACK for FF 23, which ends the download.
  SendCommand(RaceBoxCmdCancelDownload, 'cancel download');
end;

procedure TRaceBoxClient.ReadRecordingConfig;
begin
  SendCommand(RaceBoxCmdReadRecordingConfig, 'read recording configuration');
end;

procedure TRaceBoxClient.WriteRecordingConfig(const Config: TRaceBoxRecordingConfig);
begin
  SendCommand(RaceBoxCmdWriteRecordingConfig(Config), 'write recording configuration');
end;

procedure TRaceBoxClient.StartRecording;
begin
  StartRecording(TRaceBoxRecordingConfig.Default);
end;

procedure TRaceBoxClient.StartRecording(const Config: TRaceBoxRecordingConfig);
var
  C: TRaceBoxRecordingConfig;
begin
  C := Config;
  C.Enable := True;
  WriteRecordingConfig(C);
end;

procedure TRaceBoxClient.StopRecording;
var
  C: TRaceBoxRecordingConfig;
begin
  FillChar(C, SizeOf(C), 0);
  WriteRecordingConfig(C);
end;

procedure TRaceBoxClient.ReadGnssConfig;
begin
  SendCommand(RaceBoxCmdReadGnssConfig, 'read GNSS configuration');
end;

procedure TRaceBoxClient.WriteGnssConfig(const Config: TRaceBoxGnssConfig);
begin
  SendCommand(RaceBoxCmdWriteGnssConfig(Config), 'write GNSS configuration');
end;

procedure TRaceBoxClient.EraseMemory;
begin
  RequireConnected;
  if FState <> rcsConnected then
    raise Exception.Create('Wait for the current download or erase to finish.');
  SetState(rcsErasing);
  if not SendCommand(RaceBoxCmdEraseMemory, 'erase memory') then
    SetState(rcsConnected);
end;

procedure TRaceBoxClient.CancelErase;
begin
  if FState = rcsErasing then
    SendCommand(RaceBoxCmdCancelErase, 'cancel erase');
end;

{ ---------------------------------------------------------------- results }

procedure TRaceBoxClient.SaveRawDump(const FileName: string);
begin
  FLock.Enter;
  try
    FRawDump.SaveToFile(FileName);
  finally
    FLock.Leave;
  end;
end;

function TRaceBoxClient.ExtractSessions: TRaceBoxSessionList;
begin
  Result := FSessions;
  FSessions := TRaceBoxSessionList.Create(True);
end;

end.
