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
    FConnectAttempt: Integer;
    FSetupStarted: Integer;
    FWorkerThreadId: TThreadID;
    FConnectStartTick: UInt64;
    FConnectTimeoutMs: Cardinal;
    FOnStateChanged: TNotifyEvent;

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
    procedure ReadDeviceInfo(Device: TBluetoothLEDevice; Attempt: Integer; const Alive: IRaceBoxAlive);
    function IsCurrentAttempt(Attempt: Integer): Boolean;
    procedure ConnectWorker(Device: TBluetoothLEDevice; Attempt: Integer; const Alive: IRaceBoxAlive);
    procedure ConnectWatchdog(Attempt: Integer; const Alive: IRaceBoxAlive);
    procedure SetupUart(Device: TBluetoothLEDevice; Attempt: Integer; const Alive: IRaceBoxAlive);
    procedure FailConnect(Attempt: Integer; const Msg: string);
    class procedure CloseLinkInBackground(Device: TBluetoothLEDevice;
      Tx: TBluetoothGattCharacteristic); static;

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

    { Connection. Connect returns at once; OnConnected or OnError follows.
      Disconnect also cancels a connect that is still in progress. }
    procedure Connect(Index: Integer); overload;
    procedure Connect(Device: TBluetoothLEDevice); overload;
    procedure Disconnect;
    { Milliseconds since Connect, while State = rcsConnecting (else 0). }
    function ConnectElapsedMs: UInt64;

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
    { Give up connecting after this long (default 30 s, 0 = wait forever). }
    property ConnectTimeoutMs: Cardinal read FConnectTimeoutMs write FConnectTimeoutMs;
    { Fires whenever State changes: use it to show busy cursors, enable buttons. }
    property OnStateChanged: TNotifyEvent read FOnStateChanged write FOnStateChanged;

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
{$IFDEF MSWINDOWS}
  Winapi.Windows, Winapi.ActiveX,
{$ENDIF}
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
  FConnectTimeoutMs := 30000;
  FUartUUID := StringToGUID(RB_UUID_UART_SERVICE);
  FRxUUID := StringToGUID(RB_UUID_UART_RX);
  FTxUUID := StringToGUID(RB_UUID_UART_TX);
end;

destructor TRaceBoxClient.Destroy;
begin
  FAlive.Kill;               // queued events for this client now do nothing
  TInterlocked.Increment(FConnectAttempt);    // stop any connect worker
  if FDevice <> nil then
  try
    FDevice.OnServicesDiscovered := nil;
    FDevice.OnCharacteristicRead := nil;
    if FTxChar <> nil then
      FDevice.SetCharacteristicNotification(FTxChar, False);
    FDevice.Disconnect;
  except
    // never raise from a destructor
  end;
  FDevice := nil;
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
  if FState = Value then Exit;
  FState := Value;
  Post(
    procedure
    begin
      if Assigned(FOnStateChanged) then FOnStateChanged(Self);
    end);
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

{ Connecting runs on a worker thread: on Windows, DiscoverServices, turning on
  notifications and reading characteristics each wait for the radio, which can
  take many seconds and used to freeze the window. Every change to FDevice and
  the characteristic fields still happens on the main thread (through Post).
  FConnectAttempt goes up on every connect, disconnect and timeout, so a worker
  that finishes late can tell its result is no longer wanted. }
procedure TRaceBoxClient.Connect(Device: TBluetoothLEDevice);
var
  Attempt: Integer;
  Alive: IRaceBoxAlive;
begin
  if Device = nil then
    raise EArgumentNilException.Create('Device is nil');
  if FDevice <> nil then
    Disconnect;
  StopScan;
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
  FDevice := Device;
  FRxChar := nil;
  FTxChar := nil;
  FUartService := nil;
  FSetupStarted := 0;
  Attempt := TInterlocked.Increment(FConnectAttempt);
  Alive := FAlive;
  FConnectStartTick := TThread.GetTickCount64;
  Device.OnServicesDiscovered := DoServicesDiscovered;
  Device.OnCharacteristicRead := DoCharacteristicRead;
  SetState(rcsConnecting);
  Log('Connecting to ' + Device.DeviceName + '...');

  TThread.CreateAnonymousThread(
    procedure
    begin
      ConnectWorker(Device, Attempt, Alive);
    end).Start;

  if FConnectTimeoutMs > 0 then
    TThread.CreateAnonymousThread(
      procedure
      begin
        ConnectWatchdog(Attempt, Alive);
      end).Start;
end;

{ On Windows a service's characteristics are only fetched from the device the
  first time the Characteristics list is read; GetCharacteristic(UUID) on its
  own just searches the (still empty) list. So read the list first. }
function FindCharacteristic(Svc: TBluetoothGattService; const UUID: TBluetoothUUID): TBluetoothGattCharacteristic;
var
  List: TBluetoothGattCharacteristicList;
  I: Integer;
begin
  Result := nil;
  List := Svc.Characteristics;          // triggers the fetch
  if List <> nil then
    for I := 0 to List.Count - 1 do
      if IsEqualGUID(List[I].UUID, UUID) then
        Exit(List[I]);
  Result := Svc.GetCharacteristic(UUID);
end;

function CharacteristicList(Svc: TBluetoothGattService): string;
var
  List: TBluetoothGattCharacteristicList;
  I: Integer;
begin
  Result := '';
  try
    List := Svc.Characteristics;
    if List <> nil then
      for I := 0 to List.Count - 1 do
      begin
        if Result <> '' then Result := Result + ', ';
        Result := Result + GUIDToString(List[I].UUID);
      end;
  except
    on E: Exception do Result := Result + ' (' + E.Message + ')';
  end;
  if Result = '' then Result := '(none)';
end;

{ For the log: the UUIDs of the services Windows reported. }
function ServiceList(Device: TBluetoothLEDevice): string;
var
  I: Integer;
begin
  Result := '';
  try
    for I := 0 to Device.Services.Count - 1 do
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + GUIDToString(Device.Services[I].UUID);
    end;
  except
    on E: Exception do Result := Result + ' (' + E.Message + ')';
  end;
  if Result = '' then Result := '(none)';
end;

function TRaceBoxClient.IsCurrentAttempt(Attempt: Integer): Boolean;
begin
  Result := TInterlocked.CompareExchange(FConnectAttempt, 0, 0) = Attempt;
end;

function TRaceBoxClient.ConnectElapsedMs: UInt64;
begin
  if FState = rcsConnecting then
    Result := TThread.GetTickCount64 - FConnectStartTick
  else
    Result := 0;
end;

{ The client can be freed while this thread waits on the radio, so check
  Alive before touching any field after a long call. }
procedure TRaceBoxClient.ConnectWorker(Device: TBluetoothLEDevice; Attempt: Integer;
  const Alive: IRaceBoxAlive);
var
  OK: Boolean;
{$IFDEF MSWINDOWS}
  ComOK: Boolean;
{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  // The Windows Bluetooth classes use WinRT, which needs COM on this thread.
  ComOK := Succeeded(CoInitializeEx(nil, COINIT_MULTITHREADED));
{$ENDIF}
  try
    try
      FWorkerThreadId := TThread.Current.ThreadID;
      Log(Format('Step 1/3: discovering services (address %s)...', [Device.Address]));
      // On Windows this opens the GATT connection and returns when the
      // services are known.
      OK := Device.DiscoverServices;
      if not Alive.IsAlive or not IsCurrentAttempt(Attempt) then Exit;
      Log(Format('Step 1/3 done after %d ms: result %s, %d service(s): %s',
        [TThread.GetTickCount64 - FConnectStartTick, BoolToStr(OK, True),
         Device.Services.Count, ServiceList(Device)]));
      if not OK then
      begin
        FailConnect(Attempt, 'Could not connect to the RaceBox (service discovery failed). ' +
          'Make sure it is switched on and the RaceBox phone app is closed, then try again.');
        Exit;
      end;
      SetupUart(Device, Attempt, Alive);
    except
      on E: Exception do
        if Alive.IsAlive then
          FailConnect(Attempt, 'Connecting failed: ' + E.Message);
    end;
  finally
    if Alive.IsAlive and (FWorkerThreadId = TThread.Current.ThreadID) then
      FWorkerThreadId := 0;
{$IFDEF MSWINDOWS}
    if ComOK then CoUninitialize;
{$ENDIF}
  end;
end;

procedure TRaceBoxClient.ConnectWatchdog(Attempt: Integer; const Alive: IRaceBoxAlive);
begin
  while Alive.IsAlive and IsCurrentAttempt(Attempt) and (FState = rcsConnecting) do
  begin
    if TThread.GetTickCount64 - FConnectStartTick > FConnectTimeoutMs then
    begin
      FailConnect(Attempt, Format('No answer from the RaceBox after %d seconds. ' +
        'Switch it off and on, make sure the phone app is not connected to it, and try again.',
        [FConnectTimeoutMs div 1000]));
      Exit;
    end;
    TThread.Sleep(200);
  end;
end;

{ Runs on the worker thread (or the Bluetooth thread on platforms where
  services are discovered asynchronously). }
procedure TRaceBoxClient.SetupUart(Device: TBluetoothLEDevice; Attempt: Integer;
  const Alive: IRaceBoxAlive);
var
  Svc: TBluetoothGattService;
  Rx, Tx: TBluetoothGattCharacteristic;
  OK: Boolean;
begin
  if TInterlocked.CompareExchange(FSetupStarted, 1, 0) <> 0 then Exit;  // already running
  Svc := Device.GetService(FUartUUID);
  if Svc = nil then
  begin
    if Device.Services.Count = 0 then
    begin
      // Not discovered yet; OnServicesDiscovered will call us again.
      TInterlocked.Exchange(FSetupStarted, 0);
      Exit;
    end;
    FailConnect(Attempt, 'This device has no RaceBox UART service.');
    Exit;
  end;
  Rx := FindCharacteristic(Svc, FRxUUID);
  Tx := FindCharacteristic(Svc, FTxUUID);
  Log('UART service characteristics: ' + CharacteristicList(Svc));
  if (Rx = nil) or (Tx = nil) then
  begin
    FailConnect(Attempt, 'RaceBox UART characteristics not found (Windows reported: ' +
      CharacteristicList(Svc) + ').');
    Exit;
  end;
  Log('Step 2/3: turning on RaceBox notifications...');
  // Data arrives as notifications on TX, reported through OnCharacteristicRead.
  OK := Device.SetCharacteristicNotification(Tx, True);
  if not Alive.IsAlive or not IsCurrentAttempt(Attempt) then Exit;
  Log(Format('Step 2/3 done after %d ms: result %s',
    [TThread.GetTickCount64 - FConnectStartTick, BoolToStr(OK, True)]));
  if not OK then
  begin
    FailConnect(Attempt, 'Could not subscribe to RaceBox notifications.');
    Exit;
  end;
  Post(
    procedure
    begin
      if not IsCurrentAttempt(Attempt) or (FDevice <> Device) then Exit;
      FUartService := Svc;
      FRxChar := Rx;
      FTxChar := Tx;
      SetState(rcsConnected);
      if Assigned(FOnLog) then FOnLog(Self, 'Step 3/3: connected to ' + Device.DeviceName + '.');
      if Assigned(FOnConnected) then FOnConnected(Self);
    end);
  ReadDeviceInfo(Device, Attempt, Alive);
end;

{ Abandons a connect attempt; the clean-up runs on the main thread. }
procedure TRaceBoxClient.FailConnect(Attempt: Integer; const Msg: string);
begin
  // Invalidate the attempt now so the worker and watchdog stop caring.
  if TInterlocked.CompareExchange(FConnectAttempt, Attempt + 1, Attempt) <> Attempt then Exit;
  Post(
    procedure
    var
      Device: TBluetoothLEDevice;
    begin
      Device := FDevice;
      if Device <> nil then
      begin
        Device.OnServicesDiscovered := nil;
        Device.OnCharacteristicRead := nil;
        FDevice := nil;
        FRxChar := nil;
        FTxChar := nil;
        FUartService := nil;
        CloseLinkInBackground(Device, nil);
      end;
      SetState(rcsIdle);
      if Assigned(FOnError) then FOnError(Self, Msg)
      else if Assigned(FOnLog) then FOnLog(Self, 'Error: ' + Msg);
    end);
end;

procedure TRaceBoxClient.DoServicesDiscovered(const Sender: TObject;
  const AServiceList: TBluetoothGattServiceList);
begin
  // On Windows this fires inside DiscoverServices on the worker thread, which
  // carries on with SetupUart itself once DiscoverServices returns.
  if TThread.Current.ThreadID = FWorkerThreadId then Exit;
  if (Sender is TBluetoothLEDevice) and (TBluetoothLEDevice(Sender) = FDevice) then
    SetupUart(TBluetoothLEDevice(Sender), TInterlocked.CompareExchange(FConnectAttempt, 0, 0), FAlive);
end;

procedure TRaceBoxClient.ReadDeviceInfo(Device: TBluetoothLEDevice; Attempt: Integer;
  const Alive: IRaceBoxAlive);
const
  Ids: array[0..3] of string = (RB_UUID_DEVINFO_MODEL, RB_UUID_DEVINFO_SERIAL,
    RB_UUID_DEVINFO_FIRMWARE, RB_UUID_DEVINFO_HARDWARE);
var
  Svc: TBluetoothGattService;
  Ch: TBluetoothGattCharacteristic;
  I: Integer;
begin
  try
    Svc := Device.GetService(StringToGUID(RB_UUID_DEVINFO_SERVICE));
    if Svc = nil then Exit;
    for I := Low(Ids) to High(Ids) do
    begin
      if not Alive.IsAlive or not IsCurrentAttempt(Attempt) then Exit;
      Ch := FindCharacteristic(Svc, StringToGUID(Ids[I]));
      if Ch <> nil then
        Device.ReadCharacteristic(Ch);   // answer arrives in DoCharacteristicRead
    end;
  except
    // Model/serial/firmware are nice to have; never fail the connection over them.
  end;
end;

{ Turning notifications off and dropping the link can also wait on the radio,
  so do it on a throwaway thread. Uses only its parameters, never Self. }
class procedure TRaceBoxClient.CloseLinkInBackground(Device: TBluetoothLEDevice;
  Tx: TBluetoothGattCharacteristic);
begin
  TThread.CreateAnonymousThread(
    procedure
{$IFDEF MSWINDOWS}
    var
      ComOK: Boolean;
{$ENDIF}
    begin
{$IFDEF MSWINDOWS}
      ComOK := Succeeded(CoInitializeEx(nil, COINIT_MULTITHREADED));
{$ENDIF}
      try
        try
          if Tx <> nil then
            Device.SetCharacteristicNotification(Tx, False);
        except
          // the link may already be gone
        end;
        try
          Device.Disconnect;
        except
        end;
      finally
{$IFDEF MSWINDOWS}
        if ComOK then CoUninitialize;
{$ENDIF}
      end;
    end).Start;
end;

procedure TRaceBoxClient.Disconnect;
var
  Device: TBluetoothLEDevice;
  WasConnected, WasConnecting: Boolean;
begin
  Device := FDevice;
  if Device = nil then Exit;
  TInterlocked.Increment(FConnectAttempt);    // cancels a connect in progress
  WasConnected := FState in [rcsConnected, rcsDownloading, rcsErasing];
  WasConnecting := FState = rcsConnecting;
  Device.OnServicesDiscovered := nil;
  Device.OnCharacteristicRead := nil;
  CloseLinkInBackground(Device, FTxChar);
  FDevice := nil;
  FRxChar := nil;
  FTxChar := nil;
  FUartService := nil;
  FLock.Enter;
  try
    FreeAndNil(FSplitter);
  finally
    FLock.Leave;
  end;
  SetState(rcsIdle);
  if WasConnecting then
    Log('Connect cancelled.')
  else
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
