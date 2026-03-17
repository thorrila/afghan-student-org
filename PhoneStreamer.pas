unit PhoneStreamer;

{
  PHONE SIDE — FMX application
  Captures camera frames and serves them as an MJPEG stream over HTTP.

  The phone acts as the HTTP server.
  Any browser or the PC viewer app can connect to:
    http://<phone-ip>:8080/stream

  Requirements (all ship with Delphi):
    - FireMonkey (FMX)        → UI + TCameraComponent
    - Indy (IdHTTPServer)     → HTTP server, bundled with Delphi
    - System.NetEncoding      → base64 (not needed here, just JPEG bytes)

  How to deploy:
    1. Open in Delphi, set target platform to Android or iOS
    2. Enable camera permission in Project > Options > Uses Permissions
    3. Deploy to phone, note the WiFi IP address shown on screen
    4. Run PCViewer on your computer and enter that IP
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,          // TCriticalSection — protects the shared frame
  FMX.Types,
  FMX.Controls,
  FMX.Forms,
  FMX.Graphics,
  FMX.Objects,              // TImage
  FMX.StdCtrls,             // TLabel, TButton
  FMX.Media,                // TCameraComponent
  FMX.Platform,             // IFMXSystemInformationService (get IP)
  IdHTTPServer,
  IdContext,
  IdCustomHTTPServer,
  Net.Socket;               // only used to retrieve local IP

type
  TPhoneStreamForm = class(TForm)
    Camera        : TCameraComponent;
    PreviewImage  : TImage;          // shows local camera preview
    StatusLabel   : TLabel;          // shows IP address + connection count
    StartButton   : TButton;
    StopButton    : TButton;

    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure StartButtonClick(Sender: TObject);
    procedure StopButtonClick(Sender: TObject);
    procedure CameraSampleBufferReady(Sender: TObject;
                                      const ATime: TMediaTime);
  private
    FServer       : TIdHTTPServer;
    FFrameLock    : TCriticalSection;
    FCurrentFrame : TBytes;           // latest JPEG frame bytes
    FClientCount  : Integer;

    procedure ServerCommandGet(AContext: TIdContext;
                               ARequestInfo: TIdHTTPRequestInfo;
                               AResponseInfo: TIdHTTPResponseInfo);
    procedure StreamMJPEG(AContext: TIdContext);
    procedure UpdateStatus;
    function  GetLocalIPAddress: string;
    procedure CaptureFrameToBytes;
  end;

const
  SERVER_PORT    = 8080;
  MJPEG_BOUNDARY = 'mjpegframe';

implementation

{$R *.fmx}

uses
  System.Net.Socket,
  FMX.Surfaces;

{ ── Form lifecycle ─────────────────────────────────────────────── }

procedure TPhoneStreamForm.FormCreate(Sender: TObject);
begin
  FFrameLock   := TCriticalSection.Create;
  FClientCount := 0;

  // Wire up the Indy HTTP server
  FServer                    := TIdHTTPServer.Create(nil);
  FServer.DefaultPort        := SERVER_PORT;
  FServer.OnCommandGet       := ServerCommandGet;
  FServer.OnCommandOther     := ServerCommandGet; // catch POST etc. too

  // Wire camera sample callback
  Camera.OnSampleBufferReady := CameraSampleBufferReady;

  StopButton.Enabled  := False;
  StartButton.Enabled := True;
end;

procedure TPhoneStreamForm.FormDestroy(Sender: TObject);
begin
  if FServer.Active then FServer.Active := False;
  FServer.Free;
  FFrameLock.Free;
end;

{ ── Button handlers ─────────────────────────────────────────────── }

procedure TPhoneStreamForm.StartButtonClick(Sender: TObject);
begin
  Camera.Active      := True;
  FServer.Active     := True;
  StartButton.Enabled := False;
  StopButton.Enabled  := True;
  UpdateStatus;
end;

procedure TPhoneStreamForm.StopButtonClick(Sender: TObject);
begin
  Camera.Active      := False;
  FServer.Active     := False;
  StartButton.Enabled := True;
  StopButton.Enabled  := False;
  StatusLabel.Text   := 'Stopped';
end;

{ ── Camera ──────────────────────────────────────────────────────── }

procedure TPhoneStreamForm.CameraSampleBufferReady(Sender: TObject;
  const ATime: TMediaTime);
begin
  // This fires on a camera thread — capture the frame safely
  Camera.SampleBufferToBitmap(PreviewImage.Bitmap, True);
  CaptureFrameToBytes;
end;

procedure TPhoneStreamForm.CaptureFrameToBytes;
var
  Stream : TMemoryStream;
begin
  Stream := TMemoryStream.Create;
  try
    // Encode the current preview bitmap as JPEG into a memory stream
    PreviewImage.Bitmap.SaveToStream(Stream);  // FMX saves as JPEG by default
    Stream.Position := 0;

    FFrameLock.Acquire;
    try
      SetLength(FCurrentFrame, Stream.Size);
      Stream.ReadBuffer(FCurrentFrame[0], Stream.Size);
    finally
      FFrameLock.Release;
    end;
  finally
    Stream.Free;
  end;
end;

{ ── HTTP server ─────────────────────────────────────────────────── }

procedure TPhoneStreamForm.ServerCommandGet(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
begin
  if ARequestInfo.Document = '/stream' then
  begin
    // Hand off to our MJPEG streaming loop — this blocks until client disconnects
    TInterlocked.Increment(FClientCount);
    try
      StreamMJPEG(AContext);
    finally
      TInterlocked.Decrement(FClientCount);
      TThread.Queue(nil, UpdateStatus);
    end;
  end
  else if ARequestInfo.Document = '/' then
  begin
    // Simple HTML landing page so a browser can view the stream
    AResponseInfo.ContentType := 'text/html';
    AResponseInfo.ContentText :=
      '<html><body style="background:#000;margin:0">' +
      '<img src="/stream" style="width:100%;height:100vh;object-fit:contain">' +
      '</body></html>';
  end
  else
  begin
    AResponseInfo.ResponseNo   := 404;
    AResponseInfo.ContentText  := 'Not found';
  end;
end;

procedure TPhoneStreamForm.StreamMJPEG(AContext: TIdContext);
var
  IO        : TIdIOHandler;
  Frame     : TBytes;
  Header    : string;
begin
  IO := AContext.Connection.IOHandler;

  // Send the multipart HTTP header
  IO.WriteLn('HTTP/1.1 200 OK');
  IO.WriteLn('Content-Type: multipart/x-mixed-replace; boundary=' +
             MJPEG_BOUNDARY);
  IO.WriteLn('Cache-Control: no-cache');
  IO.WriteLn('Connection: close');
  IO.WriteLn('');

  TThread.Queue(nil, UpdateStatus);

  // Keep sending frames until the client disconnects
  while AContext.Connection.Connected do
  begin
    // Grab the latest frame
    FFrameLock.Acquire;
    try
      Frame := Copy(FCurrentFrame);
    finally
      FFrameLock.Release;
    end;

    if Length(Frame) > 0 then
    begin
      Header :=
        '--' + MJPEG_BOUNDARY + #13#10 +
        'Content-Type: image/jpeg'  + #13#10 +
        'Content-Length: ' + IntToStr(Length(Frame)) + #13#10 +
        #13#10;

      try
        IO.Write(Header);
        IO.Write(TIdBytes(Frame), Length(Frame));
        IO.WriteLn('');   // trailing CRLF after frame data
      except
        Break;  // client disconnected
      end;
    end;

    // ~30 fps cap  (33 ms per frame)
    Sleep(33);
  end;
end;

{ ── Helpers ─────────────────────────────────────────────────────── }

function TPhoneStreamForm.GetLocalIPAddress: string;
var
  Host : string;
  List : TStringList;
begin
  Result := '?.?.?.?';
  try
    Host := TIdStack.LocalAddress;
    if Host <> '' then Result := Host;
  except
    // fall through — show placeholder
  end;
end;

procedure TPhoneStreamForm.UpdateStatus;
begin
  // Must be called on the main thread (use TThread.Queue from background)
  StatusLabel.Text :=
    'Stream: http://' + GetLocalIPAddress + ':' +
    IntToStr(SERVER_PORT) + '/stream' + #13#10 +
    'Clients connected: ' + IntToStr(FClientCount);
end;

end.
