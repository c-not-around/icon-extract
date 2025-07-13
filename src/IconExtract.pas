{$apptype windows}

{$reference System.Drawing.dll}
{$reference System.Windows.Forms.dll}

{$resource res\icon.ico}
{$resource res\folder.png}
{$resource res\bmp.png}
{$resource res\png.png}
{$resource res\clear.png}
{$resource res\open.png}
{$resource res\save.png}

{$mainresource res\res.res}


uses
  System,
  System.IO,
  System.Reflection,
  System.Globalization,
  System.Drawing,
  System.Drawing.Imaging,
  System.Drawing.Drawing2D,
  System.Windows.Forms;


type
  FileNames = array of string;
  
  IconEntry = record
    Width   : byte;
    Height  : byte;
    Colors  : byte;
    Reserved: byte;
    Planes  : word;
    BitCount: word;
    Size    : longword;
    Offset  : longword;
  end; 


const
  ICO_HEADER_SIZE    = 6;
  ICO_HEADER_TYPE    = $0001;
  ICO_HEADER_RESERVE = $0000;
  ICO_ENTRY_SIZE     = 16;
  BMP_HEADER_SIZE    = 14;
  BMP_HEADER_TYPE    = $4D42;
  BMP_HEADER_RESERVE = $0000;
  BMP_INFO_SIZE      = 40;
  BMP_HEADER_ID      = $00000028;
  PNG_HEADER_ID      = $474E5089;
  

var
  Main       : Form;
  Sources    : TreeView;
  ImageView  : PictureBox;
  OpenSource : Button;
  SaveCurrent: Button;
  SaveAll    : Button;


{$region Routines}
function BinaryReader.ReadArgb(alpha: boolean := false): Color;
begin
  var b := self.ReadByte();
  var g := self.ReadByte();
  var r := self.ReadByte();
  var a := self.ReadByte();
          
  result := Color.FromArgb(alpha ? a : $FF, r, g, b);
end;

function Color.Mask() := Color.FromArgb($00, self.R, self.G, self.B);

function GetIconEntries(data: BinaryReader): array of IconEntry;
begin
  var length := data.BaseStream.Length;
  if length <= (ICO_HEADER_SIZE+ICO_ENTRY_SIZE) then
    raise new Exception($'Invalid file length={length}.');
  // ICO_FILE_HEADER
  if (data.ReadUInt16() <> ICO_HEADER_RESERVE) or (data.ReadUInt16() <> ICO_HEADER_TYPE) then
    raise new Exception('Invalid Header.');
  var count := data.ReadUInt16();
  if length <= (ICO_HEADER_SIZE+count*ICO_ENTRY_SIZE) then
    raise new Exception($'Invalid file length={length} for {count} Entries.');
  // ICO_ENTRIES
  result := new IconEntry[count];
  for var i := 0 to count-1 do
    with result[i] do
      begin
        Width    := data.ReadByte();
        Height   := data.ReadByte();
        Colors   := data.ReadByte();
        Reserved := data.ReadByte();
        Planes   := data.ReadUInt16();
        BitCount := data.ReadUInt16();
        Size     := data.ReadUInt32();
        Offset   := data.ReadUInt32();
      end;
end;

function ExtractBitmap(data: BinaryReader; width, height, bits: integer; params palette: array of Color): Bitmap;
begin
  var BitMask := $FF shr (8 - bits);
  var decode: integer -> integer;
  case bits of
    1: decode := w -> (w and $18) + (7 - (w and $7)); 
    4: decode := w -> 4 * ((w and $6) + (1 - (w and $1)));
    8: decode := w -> (w and $3) shl 3;
  end;
  
  result := new Bitmap(width, height);
  
  for var h := height-1 downto 0 do
    begin
      var row : longword;
      var bit := 32;
      
      for var w := 0 to width-1 do
        begin
          if bit = 32 then
            begin
              row := data.ReadUInt32();
              bit := 0;
            end;
          
          result.SetPixel(w, h, palette[(row shr decode(w)) and BitMask]);
          
          bit += bits;
        end;
    end;
end;

function ExtractBmpFrame(data: BinaryReader; offset: integer): Bitmap;
begin
  (*
  0000: uint32_t Size
  0004: uint32_t Width
  0008: uint32_t Height
  000C: uint16_t Planes
  000E: uint16_t BitCount
  0010: uint32_t Compression
  0014: uint32_t ImageSize
  0018: uint32_t PxPerMeterX
  001C: uint32_t PxPerMeterY
  0020: uint32_t ColorUsed
  0024: uint32_t ColorImport
  *)
  data.BaseStream.Position := offset + sizeof(UInt32);
  var width  := data.ReadUInt32();
  var height := data.ReadUInt32() shr 1;
  data.BaseStream.Position += sizeof(UInt16);
  var bits   := data.ReadUInt16();
  data.BaseStream.Position += 6*sizeof(UInt32);
  
  if bits <= 8 then
    begin
      var pallete := new Color[1 shl bits];
      for var i := 0 to pallete.Length-1 do
        pallete[i] := data.ReadArgb();
  
      result := ExtractBitmap(data, width, height, bits, pallete);
      
      if bits > 1 then
        begin
          var size := 4 * ((width + 31) div 32) * height;
      
          if (data.BaseStream.Length - data.BaseStream.Position) >= size then
            begin
              var mask := ExtractBitmap(data, width, height, 1,
                                        Color.FromArgb($FF, $00, $00, $00),
                                        Color.FromArgb($00, $00, $00, $00));
              
              for var w := 0 to width-1 do
                for var h := 0 to height-1 do
                  if mask.GetPixel(w, h).A = $00 then
                    begin
                      var c := result.GetPixel(w, h);
                      result.SetPixel(w, h, c.Mask());
                    end;
            end;
        end;
    end
  else
    begin
      result := new Bitmap(width, height);
  
      for var h := height-1 downto 0 do
        for var w := 0 to width-1 do
          result.SetPixel(w, h, data.ReadArgb(true));
    end;
end;

function IconExtractFrames(data: BinaryReader): List<Bitmap>;
begin
  result := new List<Bitmap>();
  
  foreach var entry in GetIconEntries(data) do
    begin
      if (entry.Offset+entry.Size) > data.BaseStream.Length then
        raise new Exception($'Incorrect Offset={entry.Offset:X8} or Size={entry.Size} of IcoEntry.');
        
      data.BaseStream.Position := entry.Offset;
      var header := data.ReadUInt32();
        
      var bmp: Bitmap;
      if header = BMP_HEADER_ID then
        begin
          bmp     := ExtractBmpFrame(data, entry.Offset);
          bmp.Tag := 'bmp';
        end
      else if header = PNG_HEADER_ID then
        begin
          var frame := new byte[entry.Size];
          data.BaseStream.Position := entry.Offset;
          data.Read(frame, 0, entry.Size);
            
          bmp     := new Bitmap(new MemoryStream(frame), true);
          bmp.Tag := 'png';
          bmp.MakeTransparent();
        end
      else
        raise new Exception($'Incorrect frame header=0x{header:X8} Offset=0x{entry.Offset}');
          
      result.Add(bmp);
    end;
end;

procedure OpenSourceFile(fname: string);
begin
  var frames: List<Bitmap>;
  var data := new BinaryReader(&File.OpenRead(fname));
  try
    frames := IconExtractFrames(data);
  except on ex: Exception do
    begin
      MessageBox.Show
      (
        $'File "{fname}" open error: {ex.Message}', 'Error',
        MessageBoxButtons.OK, MessageBoxIcon.Error
      );
      exit;
    end;
  end;
  data.Close();
  data.Dispose();
  
  var IconNode         := new TreeNode();
  IconNode.Text        := fname.Substring(fname.LastIndexOf('\')+1);
  IconNode.ToolTipText := fname;
  IconNode.ImageKey    := 'folder';
  IconNode.Tag         := frames;
  
  for var i := 0 to frames.Count-1 do
    begin
      var img := frames[i];
      
      var FrameNode              := new TreeNode();
      FrameNode.Text             := $'frame{i}_{img.Width}x{img.Height}';
      FrameNode.ImageKey         := img.Tag.ToString();
      FrameNode.SelectedImageKey := FrameNode.ImageKey;
      FrameNode.Tag              := img;
      IconNode.Nodes.Add(FrameNode);
    end;
  
  Sources.Nodes.Add(IconNode);
end;

function FrameSaveDialog(): (string, ImageFormat);
begin
  var dialog    := new SaveFileDialog();
  dialog.Title  := 'Select file name and format';
  dialog.Filter := 'Portable Network Graphics (*.png)|*.png|' +
                   'Windows Bitmap (*.bmp)|*.bmp|'            +
                   'Photo Picture (*.jpeg)|*.jpeg|'           +
                   'Graphics Interchange (*.gif)|*.gif|'      +
                   'Windows Icon (*.ico)|*.ico';
  
  if dialog.ShowDialog() = DialogResult.OK then
    begin
      var format: ImageFormat;
      case dialog.FilterIndex of
        1: format := ImageFormat.Png;
        2: format := ImageFormat.Bmp;
        3: format := ImageFormat.Jpeg;
        4: format := ImageFormat.Gif;
        5: format := ImageFormat.Icon;
      end;
      
      result := (dialog.FileName, format);
    end
  else
    result := (string.Empty, ImageFormat.MemoryBmp);
  
  dialog.Dispose();
  dialog := nil;
end;
{$endregion}

{$region Handlers}
procedure SourcesClearClick(sender: object; e: EventArgs);
begin
  SaveCurrent.Enabled := false;
  SaveAll.Enabled     := false;
  
  Sources.Nodes.Clear();
  
  ImageView.Image := nil;
end;

procedure SourcesAfterSelect(sender: object; e: TreeViewEventArgs);
begin
  if e.Node.Level > 0 then
    begin
      var bmp := e.Node.Tag as Bitmap;
      
      var b := new Bitmap(ImageView.Width, ImageView.Height);
      var g := Graphics.FromImage(b);
      for var w := 0 to 15 do
        for var h := 0 to 15 do
          begin
            var c := ((w and $01) = $01) xor ((h and $01) = $01) ? Color.LightGray : Color.White;
            g.FillRectangle(new SolidBrush(c), 16*w, 16*h, 16, 16);
          end;
      g.DrawImage(bmp, (b.Width-bmp.Width) div 2, (b.Height-bmp.Height) div 2);
      
      var old := ImageView.Image;
      
      ImageView.Image := b.Clone() as Bitmap;
      
      if old <> nil then
        begin
          old.Dispose();
          old := nil;
        end;
      
      g.Dispose();
      g := nil;
      b.Dispose();
      b := nil;
    end;
  
  SaveCurrent.Enabled := e.Node.Level > 0;
  SaveAll.Enabled     := e.Node.Level = 0;
end;

procedure SourcesDragEnter(sender: object; e: DragEventArgs);
begin
  e.Effect := DragDropEffects.All;
end;

procedure SourcesDragDrop(sender: object; e: DragEventArgs);
begin
  var files := FileNames(e.Data.GetData(DataFormats.FileDrop));
  foreach var source in files do
    OpenSourceFile(source);
end;

procedure OpenSourceClick(sender: object; e: EventArgs);
begin
  var dialog         := new OpenFileDialog();
  dialog.Title       := 'Select icon source file';
  dialog.Multiselect := true;
  dialog.Filter      := 'Windows Icon (*.ico)|*.ico';
  
  if dialog.ShowDialog() = DialogResult.OK then
    foreach var source in dialog.FileNames do
      OpenSourceFile(source);
  
  dialog.Dispose();
  dialog := nil;
end;

procedure SaveCurrentClick(sender: object; e: EventArgs);
begin
  (var fname, var format) := FrameSaveDialog();
  
  if not String.IsNullOrEmpty(fname) then
    begin
      var img := Sources.SelectedNode.Tag as Bitmap;
      img.Save(fname, format);
    end;
end;

procedure SaveAllClick(sender: object; e: EventArgs);
begin
  (var fname, var format) := FrameSaveDialog();
  
  if not String.IsNullOrEmpty(fname) then
    foreach var node: TreeNode in Sources.SelectedNode.Nodes do
      begin
        var img := node.Tag as Bitmap;
        img.Save(fname.Insert(fname.LastIndexOf('.'), '_'+node.Text), format);
      end;
end;
{$endregion}

begin
  {$region App}
  Application.EnableVisualStyles();
  Application.SetCompatibleTextRenderingDefault(false);
  {$endregion}
  
  {$region MainForm}
  Main               := new Form();
  Main.Size          := new Size(537, 340);
  Main.MinimumSize   := new Size(537, 340);
  Main.MaximumSize   := new Size(999, 340);
  Main.Icon          := new Icon(System.Reflection.Assembly.GetEntryAssembly().GetManifestResourceStream('icon.ico'));
  Main.StartPosition := FormStartPosition.CenterScreen;
  Main.Text          := 'IconExtract';
  {$endregion}
  
  {$region Sources}
  var ImgList        := new ImageList();
  ImgList.ColorDepth := ColorDepth.Depth32Bit;
  ImgList.ImageSize  := new Size(16, 16);
  ImgList.Images.Add('folder', Image.FromStream(System.Reflection.Assembly.GetEntryAssembly().GetManifestResourceStream('folder.png')));
  ImgList.Images.Add('bmp', Image.FromStream(System.Reflection.Assembly.GetEntryAssembly().GetManifestResourceStream('bmp.png')));
  ImgList.Images.Add('png', Image.FromStream(System.Reflection.Assembly.GetEntryAssembly().GetManifestResourceStream('png.png')));
  
  var SourcesMenu    := new ContextMenuStrip();
  var SourcesClear   := new ToolStripMenuItem();
  SourcesClear.Text  := 'Clear'; 
  SourcesClear.Image := Image.FromStream(System.Reflection.Assembly.GetEntryAssembly().GetManifestResourceStream('clear.png'));
  SourcesClear.Click += SourcesClearClick;
  SourcesMenu.Items.Add(SourcesClear);
  
  Sources                  := new TreeView();
  Sources.Location         := new Point(5, 5);
  Sources.Size             := new Size(250, 256);
  Sources.Anchor           := AnchorStyles.Left or AnchorStyles.Right or AnchorStyles.Top;
  Sources.ItemHeight       := 18;
  Sources.ImageList        := ImgList;
  Sources.ContextMenuStrip := SourcesMenu;
  Sources.ShowRootLines    := true;
  Sources.ShowPlusMinus    := true;
  Sources.Scrollable       := true;
  Sources.ShowNodeToolTips := true;
  Sources.AfterSelect      += SourcesAfterSelect;
  Sources.AllowDrop        := true;
  Sources.DragEnter        += SourcesDragEnter;
  Sources.DragDrop         += SourcesDragDrop;
  Main.Controls.Add(Sources);
  {$endregion}
  
  {$region ImageView}
  ImageView           := new PictureBox();
  ImageView.Size      := new Size(256, 256);
  ImageView.Location  := new Point(Sources.Left+Sources.Width+5, Sources.Top);
  ImageView.Anchor    := AnchorStyles.Right or AnchorStyles.Top;
  ImageView.BackColor := Color.White;
  Main.Controls.Add(ImageView);
  {$endregion}
  
  {$region Buttons}
  SaveAll            := new Button();
  SaveAll.Size       := new Size(80, 24);
  SaveAll.Location   := new Point(ImageView.Left+ImageView.Width-SaveAll.Width+1, ImageView.Top+ImageView.Height+10);
  SaveAll.Anchor     := AnchorStyles.Right or AnchorStyles.Bottom;
  SaveAll.Text       := '  Save All';
  SaveAll.ImageAlign := ContentAlignment.MiddleLeft;
  SaveAll.Image      := Image.FromStream(System.Reflection.Assembly.GetEntryAssembly().GetManifestResourceStream('save.png'));
  SaveAll.Enabled    := false;
  SaveAll.Click      += SaveAllClick;
  Main.Controls.Add(SaveAll);
  
  SaveCurrent            := new Button();
  SaveCurrent.Size       := new Size(SaveAll.Width, SaveAll.Height);
  SaveCurrent.Location   := new Point(SaveAll.Left-SaveCurrent.Width-5, SaveAll.Top);
  SaveCurrent.Anchor     := AnchorStyles.Right or AnchorStyles.Bottom;
  SaveCurrent.Text       := '  Save';
  SaveCurrent.ImageAlign := ContentAlignment.MiddleLeft;
  SaveCurrent.Image      := Image.FromStream(System.Reflection.Assembly.GetEntryAssembly().GetManifestResourceStream('save.png'));
  SaveCurrent.Enabled    := false;
  SaveCurrent.Click      += SaveCurrentClick;
  Main.Controls.Add(SaveCurrent);
  
  OpenSource            := new Button();
  OpenSource.Size       := new Size(SaveCurrent.Width, SaveCurrent.Height);
  OpenSource.Location   := new Point(SaveCurrent.Left-SaveCurrent.Width-5, SaveCurrent.Top);
  OpenSource.Anchor     := AnchorStyles.Right or AnchorStyles.Bottom;
  OpenSource.Text       := '  Open';
  OpenSource.ImageAlign := ContentAlignment.MiddleLeft;
  OpenSource.Image      := Image.FromStream(System.Reflection.Assembly.GetEntryAssembly().GetManifestResourceStream('open.png'));
  OpenSource.Click      += OpenSourceClick;
  Main.Controls.Add(OpenSource);
  {$endregion}
  
  {$region App}
  begin
    var args := Environment.GetCommandLineArgs();
    
    if (args.Length > 1) and (args[1] <> '[REDIRECTIOMODE]') then
      for var i := 1 to args.Length-1 do
        OpenSourceFile(args[i].Trim('"'));
  end;
  
  Application.Run(Main);
  {$endregion}
end.


{$region ICO & BMP Structure}
(*
ICO:
  ICO_FILE_HEADER
  ICO_ENTRY_0
  ICO_ENTRY_1
  ...
  ICO_ENTRY_n
  BMP_INFO_HEADER_0
  BMP_DATA_0
  BMP_INFO_HEADER_1
  BMP_DATA_1
  ...
  BMP_INFO_HEADER_n
  BMP_DATA_n

BMP:
  BMP_FILE_HEADER
  BMP_INFO_HEADER
  BMP_DATA

BMP_FILE_HEADER[14]
  0000: uint16_t Type
  0002: uint32_t Size
  0006: uint16_t Reserved1
  0008: uint16_t Reserved2
  000A: uint32_t Offset

BMP_INFO_HEADER[40]
  0000: uint32_t Size
  0004: uint32_t Width
  0008: uint32_t Height
  000C: uint16_t Planes
  000E: uint16_t BitCount
  0010: uint32_t Compression
  0014: uint32_t ImageSize
  0018: uint32_t PxPerMeterX
  001C: uint32_t PxPerMeterY
  0020: uint32_t ColorUsed
  0024: uint32_t ColorImport

ICO_FILE_HEADER[6]
  0000: uint16_t Reserved
  0002: uint16_t Type
  0004: uint16_t Count

ICO_ENTRY[16]
  0000: uint08_t Width
  0001: uint08_t Height
  0002: uint08_t ColorCount
  0003: uint08_t Reserved
  0004: uint16_t Planes
  0006: uint16_t BitCount
  0008: uint32_t Size
  000C: uint32_t Offset
*)
{$endregion}