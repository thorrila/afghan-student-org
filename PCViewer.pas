unit PCViewer;

{
  PC SIDE — FMX (or VCL) application
  Connects to the phone's MJPEG stream and displays it in a window.

  Enter the phone's IP address, press Connect, and the video appears.

  Requirements (all ship with Delphi):
    - Indy (IdHTTP, IdTCPClient)  → bundled with Delphi
    - FMX or VCL                  → UI

  Usage:
    1. Start the PhoneStreamer app on the phone
    2. Note the IP shown on the phone screen
    3. Run this app on the PC, type the IP, press Connect
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  FMX.Types,
  FMX.Controls,
  FMX.Forms,
  FMX.Graphics,
  FMX.Objects,
  FMX.StdCtrls,
  FMX.Edit,
  IdTCPClient,
  IdGlobal;

type
  { Background thread that reads the MJPEG stream }
  TMJPEGThread = class(TThread)
  private
    FClient    : TIdTCPClient;
    FOnFrame   : TProc<TBytes>;   // called with each raw JPEG frame
    FHost      : string;
    FPort      : Integer;
    procedure ParseStream;
    function  ReadUntilCRLF: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AHost: string; APort: Integer;
                       AOnFrame: TProc<TBytes>);
    destructor  Destroy; override;
  end;

  { Main viewer form }
  TPCViewerForm = class(TForm)
    IPEdit        : TEdit;           // user types phone IP here
    PortEdit      : TEdit;           // default 8080
    ConnectButton : TButton;
    DisconnectButton : TButton;
    DisplayImage  : TImage;          // where the video appears
    StatusLabel   : TLabel;
    FPSLabel      : TLabel;

    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure ConnectButtonClick(Sender: TObject);
    procedure DisconnectButtonClick(Sender: TObject);
  private
    FThread      : TMJPEGThread;
    FFrameLock   : TCriticalSection;
    FFrameCount  : Integer;
    FLastFPSTime : TDateTime;
    FTimer       : TTimer;

    procedure OnFrameReceived(const FrameBytes: TBytes);
    procedure OnTimerTick(Sender: TObject);
    procedure SetConnected(AConnected: Boolean);
  end;

const
  DEFAULT_PORT = 8080;

implementation

{$R *.fmx}

uses
  System.DateUtils;

{ ══════════════════════════════════════════════════════════════════
  TMJPEGThread
  ══════════════════════════════════════════════════════════════════ }

constructor TMJPEGThread.Create(const AHost: string; APort: Integer;
  AOnFrame: TProc<TBytes>);
begin
  FHost    := AHost;
  FPort    := APort;
  FOnFrame := AOnFrame;
  FClient  := TIdTCPClient.Create(nil);

  FreeOnTerminate := False;
  inherited Create(False);   // start immediately
end;

destructor TMJPEGThread.Destroy;
begin
  if FClient.Connected then FClient.Disconnect;
  FClient.Free;
  inherited Destroy;
end;

procedure TMJPEGThread.Execute;
begin
  try
    FClient.Host            := FHost;
    FClient.Port            := FPort;
    FClient.ConnectTimeout  := 5000;
    FClient.Connect;

    // Send a minimal HTTP GET request for the MJPEG stream
    FClient.IOHandler.WriteLn('GET /stream HTTP/1.1');
    FClient.IOHandler.WriteLn('Host: ' + FHost + ':' + IntToStr(FPort));
    FClient.IOHandler.WriteLn('Connection: keep-alive');
    FClient.IOHandler.WriteLn('');   // blank line ends request headers

    ParseStream;
  except
    // Connection refused, timeout, etc. — thread exits cleanly
  end;
end;

function TMJPEGThread.ReadUntilCRLF: string;
begin
  Result := FClient.IOHandler.ReadLn;   // Indy ReadLn strips the CRLF
end;

procedure TMJPEGThread.ParseStream;
{
  MJPEG over HTTP looks like this on the wire:

    HTTP/1.1 200 OK
    Content-Type: multipart/x-mixed-replace; boundary=mjpegframe
    <blank line>
    --mjpegframe
    Content-Type: image/jpeg
    Content-Length: 12345
    <blank line>
    <12345 bytes of JPEG data>
    --mjpegframe
    ...
}
var
  Line        : string;
  ContentLen  : Integer;
  JpegBytes   : TIdBytes;
  FrameBytes  : TBytes;
begin
  // Skip HTTP response headers (read until blank line)
  repeat
    Line := ReadUntilCRLF;
  until Terminated or (Trim(Line) = '');

  // Main frame loop
  while not Terminated and FClient.Connected do
  begin
    // Read part headers
    ContentLen := 0;
    repeat
      Line := ReadUntilCRLF;
      // Look for Content-Length inside the part header
      if StartsText('content-length:', LowerCase(Line)) then
        ContentLen := StrToIntDef(
          Trim(Copy(Line, Pos(':', Line) + 1, MaxInt)), 0);
    until Terminated or (Trim(Line) = '');

    if Terminated then Break;

    // Read exactly ContentLen bytes of JPEG data
    if ContentLen > 0 then
    begin
      FClient.IOHandler.ReadBytes(JpegBytes, ContentLen, False);

      // Convert TIdBytes → TBytes and fire callback on main thread
      SetLength(FrameBytes, ContentLen);
      Move(JpegBytes[0], FrameBytes[0], ContentLen);

      if Assigned(FOnFrame) then
        TThread.Queue(nil,
          procedure begin FOnFrame(FrameBytes) end);
    end;
  end;
end;

{ ══════════════════════════════════════════════════════════════════
  TPCViewerForm
  ══════════════════════════════════════════════════════════════════ }

procedure TPCViewerForm.FormCreate(Sender: TObject);
begin
  FFrameLock   := TCriticalSection.Create;
  FFrameCount  := 0;
  FLastFPSTime := Now;

  IPEdit.Text   := '192.168.1.100';   // placeholder — user overwrites this
  PortEdit.Text := IntToStr(DEFAULT_PORT);

  // FPS display timer
  FTimer          := TTimer.Create(Self);
  FTimer.Interval := 1000;
  FTimer.OnTimer  := OnTimerTick;
  FTimer.Enabled  := False;

  SetConnected(False);
end;

procedure TPCViewerForm.FormDestroy(Sender: TObject);
begin
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    FThread.WaitFor;
    FThread.Free;
  end;
  FFrameLock.Free;
end;

procedure TPCViewerForm.ConnectButtonClick(Sender: TObject);
var
  Host : string;
  Port : Integer;
begin
  Host := Trim(IPEdit.Text);
  Port := StrToIntDef(Trim(PortEdit.Text), DEFAULT_PORT);

  if Host = '' then
  begin
    StatusLabel.Text := 'Please enter the phone IP address';
    Exit;
  end;

  StatusLabel.Text := 'Connecting to ' + Host + ':' + IntToStr(Port) + ' …';

  FThread := TMJPEGThread.Create(Host, Port, OnFrameReceived);

  FTimer.Enabled := True;
  SetConnected(True);
end;

procedure TPCViewerForm.DisconnectButtonClick(Sender: TObject);
begin
  FTimer.Enabled := False;

  if Assigned(FThread) then
  begin
    FThread.Terminate;
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;

  SetConnected(False);
  StatusLabel.Text    := 'Disconnected';
  FPSLabel.Text       := '';
  DisplayImage.Bitmap.Assign(nil);  // clear the display
end;

{ Called from the background thread via TThread.Queue (safe — main thread) }
procedure TPCViewerForm.OnFrameReceived(const FrameBytes: TBytes);
var
  Stream : TMemoryStream;
begin
  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(FrameBytes[0], Length(FrameBytes));
    Stream.Position := 0;

    // Decode JPEG bytes into the display bitmap
    DisplayImage.Bitmap.LoadFromStream(Stream);
  finally
    Stream.Free;
  end;

  // Count for FPS display
  FFrameLock.Acquire;
  try
    Inc(FFrameCount);
  finally
    FFrameLock.Release;
  end;

  StatusLabel.Text := 'Streaming  ●';
end;

procedure TPCViewerForm.OnTimerTick(Sender: TObject);
var
  FPS   : Double;
  Count : Integer;
begin
  FFrameLock.Acquire;
  try
    Count       := FFrameCount;
    FFrameCount := 0;
  finally
    FFrameLock.Release;
  end;

  // Timer fires every second so Count ≈ frames per second
  FPS := Count;
  FPSLabel.Text := Format('%.0f fps', [FPS]);

  // If thread died (phone disconnected), update UI
  if Assigned(FThread) and FThread.Finished then
  begin
    SetConnected(False);
    StatusLabel.Text := 'Connection lost';
    FTimer.Enabled   := False;
    FreeAndNil(FThread);
  end;
end;

procedure TPCViewerForm.SetConnected(AConnected: Boolean);
begin
  ConnectButton.Enabled    := not AConnected;
  DisconnectButton.Enabled := AConnected;
  IPEdit.Enabled           := not AConnected;
  PortEdit.Enabled         := not AConnected;
end;

end.
