{

DelphiProtocolBuffer: ProtBufParse.pas

Copyright 2014-2016 Stijn Sanders
Made available under terms described in file "LICENSE"
https://github.com/stijnsanders/DelphiProtocolBuffer

}
unit ProtBufParse;

interface

uses SysUtils, Classes;

type
  TProtocolBufferParserValue=(
    pbpvUnitName,
    pbpvTypePrefix,
    pbpvImportPath,
    pbpvAddPrefix,
    //add new here above
    pbpv_Unknown);
  TProtocolBufferParserFlag=(
    pbpfPrependNameParent,
    pbpfPrependEnumName,
    pbpfPrependEnumFields,
    pbpfDebugData,
    //add new here above
    pbpf_Unknown);

  TProtocolBufferParserValues=array[TProtocolBufferParserValue] of string;

const
  ProtocolBufferParserValueName:TProtocolBufferParserValues=(
    'u<UnitName>',
    'p<TypePrefix>',
    'i<ImportPath>',
    'a<AddPrefix>',
    //add new here above
    '');
  ProtocolBufferParserValueDefaults:TProtocolBufferParserValues=(
    '',
    'T',
    '',
    'Add_',
    //add new here above
    '');
  ProtocolBufferParserFlagName:array[TProtocolBufferParserFlag] of string=(
    'Pn: prepend with parent name',
    'En: prepend enumeration name with parent',
    'Ef: prepend enumeration field with name',
    'Dd: include debug data',
    //add new here above
    '');

type
  EProtocolBufferParseError=class(Exception);

  TProtocolBufferParser=class;//forward

  TProtocolBufferParserFlags=set of TProtocolBufferParserFlag;

  TProtBufMessageDescriptor=class(TObject)
  private
    FName,FPasName:string;
    FMembers:array of record
      Key,Quant,TypeNr:integer;
      Name,TypeName,DefaultValue,PascalType,OneOfName:string;
    end;
    FMembersIndex,FMembersCount,FHighKey:integer;
    FWireFlags:cardinal;
  protected
    function GenerateInterface(p:TProtocolBufferParser;
      Flags:TProtocolBufferParserFlags):string; virtual;
    function GenerateImplementation(p:TProtocolBufferParser;
      Flags:TProtocolBufferParserFlags):string; virtual;
  public
    Parent:TProtBufMessageDescriptor;
    NextKey,ExtensionsLo,ExtensionsHi:integer;
    Forwarded,Extending:boolean;
    OneOfName:string;
    constructor Create(const Name:string);
    procedure AddMember(Quant,TypeNr:integer;
      const Name,TypeName,DefaultValue:string);
    function MemberByKey(Key: integer; var FieldName, FieldType: string;
      var Quant, TypeNr: integer): boolean;
    property Name:string read FName;
    property PasName:string read FPasName;
  end;

  TProtBufEnumDescriptor=class(TProtBufMessageDescriptor)
  protected
    function GenerateInterface(p:TProtocolBufferParser;
      Flags:TProtocolBufferParserFlags):string; override;
    function GenerateImplementation(p:TProtocolBufferParser;
      Flags:TProtocolBufferParserFlags):string; override;
  end;

  TProtocolBufferParser=class(TObject)
  private
    FPackageName,FUnitName:string;
    FMsgDesc:array of TProtBufMessageDescriptor;
    FMsgDescIndex,FMsgDescSize:integer;
    procedure AddMsgDesc(x:TProtBufMessageDescriptor);
    procedure InsertMsgDesc(x,before:TProtBufMessageDescriptor);
  public
    Values:TProtocolBufferParserValues;
    Options:TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Parse(const FilePath:string);
    function MsgDescByName(OptParent: TProtBufMessageDescriptor;
      const Name:string):TProtBufMessageDescriptor;
    procedure ListDescriptors(const List:TStrings);
    function GenerateUnit(Flags:TProtocolBufferParserFlags):string;
    property DescriptorCount: integer read FMsgDescIndex;
  end;

const
  Quant_Required=1;
  Quant_Optional=2;
  Quant_Repeated=3;
  Quant_Repeated_Packed=4;

  //varint
  TypeNr_int32=$10;
  TypeNr_int64=$11;
  TypeNr_uint32=$12;
  TypeNr_uint64=$13;
  TypeNr_sint32=$14;
  TypeNr_sint64=$15;
  TypeNr_bool=$16;
  TypeNr_enum=$17;
  //length delimited
  TypeNr_string=$20;
  TypeNr_bytes=$21;
  TypeNr_msg=$22;
  //fixed
  TypeNr_fixed32=$30;
  TypeNr_fixed64=$40;
  TypeNr_sfixed32=$31;
  TypeNr_sfixed64=$41;
  TypeNr_float=$32;
  TypeNr_double=$42;
  //depends:enum/message/map
  TypeNr__typeByName=$01;
  TypeNr__map=$02;

  WireFlag_VarInt     = $002;// shl 1
  WireFlag_Len        = $004;// shl 2
  WireFlag_32         = $008;// shl 3
  WireFlag_64         = $010;// shl 4
  WireFlag_Msg        = $040;// shl 6
  WireFlag_Default    = $080;// shl 7
  WireFlag_RepeatBase = $100;// shl 8

  kFirstReservedNumber = 19000;
  kLastReservedNumber  = 19999;

implementation

uses SelfVersion;

{ TProtocolBufferParser }

constructor TProtocolBufferParser.Create;
begin
  inherited Create;
  FPackageName:='';
  FUnitName:='';
  FMsgDescIndex:=0;
  FMsgDescSize:=0;
  Values:=ProtocolBufferParserValueDefaults;
  Options:=TStringList.Create;
end;

destructor TProtocolBufferParser.Destroy;
begin
  while FMsgDescIndex<>0 do
   begin
    dec(FMsgDescIndex);
    FreeAndNil(FMsgDesc[FMsgDescIndex]);
   end;
  Options.Free;
  inherited;
end;

procedure TProtocolBufferParser.AddMsgDesc(x: TProtBufMessageDescriptor);
begin
  //TODO: check unique name, (auto-enable pbpfPrependNameParent?)
  if FMsgDescIndex=FMsgDescSize then
   begin
    inc(FMsgDescSize,32);//Grow
    SetLength(FMsgDesc,FMsgDescSize);
   end;
  FMsgDesc[FMsgDescIndex]:=x;
  inc(FMsgDescIndex);
end;

procedure TProtocolBufferParser.InsertMsgDesc(x,
  before: TProtBufMessageDescriptor);
var
  i,j:integer;
begin
  if FMsgDescIndex=FMsgDescSize then
   begin
    inc(FMsgDescSize,32);//Grow
    SetLength(FMsgDesc,FMsgDescSize);
   end;
  i:=FMsgDescIndex;
  if i<>0 then
   begin
    dec(i);
    while (i<>0) and (FMsgDesc[i]<>before) do dec(i);
   end;
  j:=FMsgDescIndex;
  while (j<>i) do
   begin
    FMsgDesc[j]:=FMsgDesc[j-1];
    dec(j);
   end;
  FMsgDesc[i]:=x;
  inc(FMsgDescIndex);
end;

function pd(const x:string):string;
begin
  if x='' then Result:='' else Result:=IncludeTrailingPathDelimiter(x);
end;

procedure TProtocolBufferParser.Parse(const FilePath: string);
var
  Line,CodeL,CodeI,CodeJ,CodeI_EOL:integer;
  Code,Keyword:string;

  procedure LoadCode;
  var
    f:TFileStream;
  begin
    f:=TFileStream.Create(FilePath,fmOpenRead or fmShareDenyWrite);
    try
      //TODO: UTF-8? UTF-16?
      CodeL:=f.Size;
      SetLength(Code,CodeL);
      if f.Read(Code[1],CodeL)<>CodeL then RaiseLastOSError;
    finally
      f.Free;
    end;
  end;

  procedure SkipWhiteSpace;
  var
    b:boolean;
  begin
    b:=true;
    while b or ((CodeI<=CodeL) and (Code[CodeI]<=' ')) do
     begin
      b:=false;
      while (CodeI<=CodeL) and (Code[CodeI]<=' ') do
       begin
        if (Code[CodeI]=#10) then
         begin
          inc(Line);
          CodeI_EOL:=CodeI;
         end
        else
          if (Code[CodeI]=#13) then
           begin
            inc(Line);
            if (CodeI<CodeL) and (Code[CodeI+1]=#10) then inc(CodeI);
            CodeI_EOL:=CodeI;
           end;
        inc(CodeI);
       end;
      //TODO: support /* */ ?
      if (CodeI<CodeL) and (Code[CodeI]='/') and (Code[CodeI+1]='/') then
       begin
        //skip comment to EOL
        while (CodeI<=CodeL)
          and (Code[CodeI]<>#13) and (Code[CodeI]<>#10) do
          inc(CodeI);
       end;
     end;
  end;

  procedure R(const Msg:string);
    function ReturnAddr: pointer;
    asm
      mov eax,[ebp+4]
    end;
  begin
    raise EProtocolBufferParseError.CreateFmt(
      '%s, line %d pos %d',[Msg,Line,CodeI-CodeI_EOL]) at ReturnAddr;
  end;

  procedure Expect(x:char);
  begin
    SkipWhiteSpace;
    if (CodeI<=CodeL) and (Code[CodeI]=x) then
      inc(CodeI)
    else
      R('Expected "'+x+'"');
  end;

  function IsNext(x:char):boolean;
  begin
    SkipWhiteSpace;
    if (CodeI<=CodeL) and (Code[CodeI]=x) then
     begin
      inc(CodeI);
      Result:=true;
     end
    else
      Result:=false;
  end;

  function NextKeyword:boolean;
  begin
    SkipWhiteSpace;
    CodeJ:=CodeI;
    //while (CodeJ<=CodeL) and (Code[CodeJ]>' ') do inc(CodeJ);
    while (CodeJ<=CodeL)
      and (Code[CodeJ] in ['A'..'Z','a'..'z','0'..'9','_','.']) do
      inc(CodeJ);
    Keyword:=Copy(Code,CodeI,CodeJ-CodeI);
    Result:=CodeJ>CodeI;
    CodeI:=CodeJ;
  end;

  function NextInt:integer;
  begin
    SkipWhiteSpace;
    //TODO: support '-'?
    Result:=0;
    if (CodeI<CodeL) and (Code[CodeI]='0') and (Code[CodeI+1]='x') then
     begin
      inc(CodeI,2);
      while (CodeI<=CodeL) and (Code[CodeI] in ['0'..'9','A'..'F','a'..'f']) do
       begin
        Result:=(Result shl 4) or ((byte(Code[CodeI]) and $F)+
          9*((byte(Code[CodeI]) shr 6) and 1));
        inc(CodeI);
       end;
     end
    else
     begin
      while (CodeI<=CodeL) and (Code[CodeI] in ['0'..'9']) do
       begin
        Result:=Result*10+(byte(Code[CodeI]) and $F);
        inc(CodeI);
       end;
     end;
  end;

  function NextStr:string;
  begin
    Expect('"');
    Result:='';
    while (CodeI<=CodeL) and (Code[CodeI]<>'"') do
     begin
      if (Code[CodeI]='\') and (CodeI<CodeL) then
       begin
        inc(CodeI);
        Result:=Result+Code[CodeI];
       end
      else
        Result:=Result+Code[CodeI];//TODO: more Copy's!
      inc(CodeI);
     end;
    //Expect('"');
    if (CodeI<=CodeL) and (Code[CodeI]='"') then
      inc(CodeI)
    else
      R('Expected end of string quotes');
  end;

var
  FieldName,TypeName,DefaultValue,OptionName:string;
  Quant,TypeNr:integer;
  First:boolean;
  Msg,Msg1,MsgEnum:TProtBufMessageDescriptor;
begin
  FUnitName:=ChangeFileExt(ExtractFileName(FilePath),'');
  LoadCode;
  CodeL:=Length(Code);
  CodeI:=1;
  CodeI_EOL:=0;
  Line:=1;
  Keyword:='';
  Msg:=nil;
  MsgEnum:=nil;

  while (CodeI<=CodeL) do

    if (Msg=nil) and (MsgEnum=nil) then
     begin

      if NextKeyword then
        if Keyword='syntax' then
         begin
          Expect('=');
          NextStr;//expect 'proto3'? flag 'proto2'?
          Expect(';');
         end
        else
        if Keyword='package' then
         begin
          if FPackageName<>'' then R('Package name was already set');
          if NextKeyword then FPackageName:=Keyword else R('Package name expected');
          Expect(';');
         end
        else
        if Keyword='import' then
         begin
          if NextKeyword then
            if Keyword='public' then
              //TODO
            else
            if Keyword='weak' then
              //TODO
            else
              R('Unsupported import moidifier');
          Parse(pd(Values[pbpvImportPath])+StringReplace(NextStr,'/','\',[rfReplaceAll]));
          Expect(';');
         end
        else
        if Keyword='option' then
         begin
          if IsNext('(') then
           begin
            if not NextKeyword then R('Option name expected');
            OptionName:=Keyword;
            while IsNext('.') do
             begin
              if not NextKeyword then R('Option name expected');
              OptionName:=OptionName+'.'+Keyword;
             end;
            Expect(')');
           end
          else
           begin
            if not NextKeyword then R('Option name expected');
            OptionName:=Keyword;
           end;
          while IsNext('.') do
           begin
            if not NextKeyword then R('Option name expected');
            OptionName:=OptionName+'.'+Keyword;
           end;
          Expect('=');
          if not NextKeyword then Keyword:=NextStr;
          Options.Add(OptionName+'='+Keyword);
          Expect(';');
         end
        else
        //TODO: 'service'
        if Keyword='message' then
         begin
          if not NextKeyword then R('Message identifier expected');
          Expect('{');
          Msg:=TProtBufMessageDescriptor.Create(Keyword);
          AddMsgDesc(Msg);
         end
        else
        if Keyword='extend' then
         begin
          if not NextKeyword then R('Extend identifier expected');
          Expect('{');
          Msg:=MsgDescByName(nil,Keyword);
          if Msg=nil then
            raise Exception.Create('Extend descriptor "'+Keyword+'" not found');
          Msg.Extending:=true;
          Msg.NextKey:=Msg.ExtensionsLo;//assert<>0
         end
        else
        if Keyword='enum' then
         begin
          if not NextKeyword then R('Enum identifier expected');
          Expect('{');
          MsgEnum:=TProtBufEnumDescriptor.Create(Keyword);
          InsertMsgDesc(MsgEnum,nil);
          //MsgEnum.Parent:=Msg;
          MsgEnum.NextKey:=0;
         end
        else
          R('Unexpected keyword "'+Keyword+'"')
      else
        if CodeI<=CodeL then
          R('Unexpected non-keyword');
        //else EOF

     end
    else

    if MsgEnum=nil then //Msg<>nil
     begin

      if NextKeyword then
        if Keyword='enum' then
         begin
          if not NextKeyword then R('Enum identifier expected');
          Expect('{');
          MsgEnum:=TProtBufEnumDescriptor.Create(Keyword);
          InsertMsgDesc(MsgEnum,Msg);
          MsgEnum.Parent:=Msg;
          MsgEnum.NextKey:=0;
         end
        else
        if Keyword='message' then
         begin
          //nested message
          if not NextKeyword then R('Message identifier expected');
          Expect('{');
          //push message
          Msg1:=Msg;
          Msg:=TProtBufMessageDescriptor.Create(Keyword);
          AddMsgDesc(Msg);
          Msg.Parent:=Msg1;
         end
        else
        if Keyword='extensions' then //TODO: proto2 only
         begin
          //extensions
          if (Msg.ExtensionsLo<>0) then R('Extensions range already set');
          if Msg.Extending then R('Can''t set extensions range when already extending');
          Msg.ExtensionsLo:=NextInt;
          if not(NextKeyword) or (Keyword<>'to') then R('Expected "to"');
          if NextKeyword then
            if Keyword='max' then
              Msg.ExtensionsHi:=$1FFFFFFF//int23
            else
            if TryStrToInt(Keyword,Msg.ExtensionsHi) then
            else
              R('Unsupported range syntax')
          else
            Msg.ExtensionsHi:=NextInt;
          if (Msg.ExtensionsLo=0) or (Msg.ExtensionsHi=0)
            or (Msg.ExtensionsHi<Msg.ExtensionsLo) then
              R('Invalid extensions range');
          Expect(';');
         end
        else
        if Keyword='option' then
         begin
          if IsNext('(') then
           begin
            if not NextKeyword then R('Option name expected');
            OptionName:=Keyword;
            while IsNext('.') do
             begin
              if not NextKeyword then R('Option name expected');
              OptionName:=OptionName+'.'+Keyword;
             end;
            Expect(')');
           end
          else
           begin
            if not NextKeyword then R('Option name expected');
            OptionName:=Keyword;
           end;
          while IsNext('.') do
           begin
            if not NextKeyword then R('Option name expected');
            OptionName:=OptionName+'.'+Keyword;
           end;
          Expect('=');
          if not NextKeyword then Keyword:=NextStr;
          //TODO: Msg.OptionAdd(OptionName,Keyword);
          Expect(';');
         end
        else
        if Keyword='reserved' then
         begin
          //TODO:
          if NextKeyword then //if (CodeI<=CodeL) and (Code[CodeI] in ['0'..'9']) then
           begin
            First:=true;
            while First or IsNext(',') do
             begin
              if First then First:=false;
              if NextKeyword then
               begin
                if Keyword='to' then NextInt//TODO:
                else ;//
               end;
              //Keyword StrToInt?
             end;
           end
          else
           begin
            NextStr;
            while IsNext(',') do NextStr;
           end;
          Expect(';');
         end
        else
        if Keyword='oneof' then
         begin
          if Msg.OneOfName<>'' then R('Nested oneof not allowed');
          if not NextKeyword then R('Message identifier expected');
          Expect('{');
          Msg.OneOfName:=Keyword;//see below
         end
        else
         begin
          //field
          if Keyword='required' then Quant:=Quant_Required else //TODO: proto2 only
          if Keyword='optional' then Quant:=Quant_Optional else //TODO: proto2 only
          if Keyword='repeated' then Quant:=Quant_Repeated else
            Quant:=0;

          if Quant<>0 then
            if not NextKeyword then R('Type identifier expected');
          DefaultValue:='';
          if Keyword='map' then
           begin
            if Quant<>0 then R('Quantifiers not allowed on maps');
            Expect('<');
            if not NextKeyword then R('Map key type expected');
            TypeNr:=0;
            case Keyword[1] of
              'b':
                if Keyword='bool' then TypeNr:=TypeNr_bool
                else
                ;
              'f':
                if Keyword='fixed32' then TypeNr:=TypeNr_fixed32
                else
                if Keyword='fixed64' then TypeNr:=TypeNr_fixed64
                else
                ;
              'i':
                if Keyword='int32' then TypeNr:=TypeNr_int32
                else
                if Keyword='int64' then TypeNr:=TypeNr_int64
                ;
              's':
                if Keyword='string' then TypeNr:=TypeNr_string
                else
                if Keyword='sint32' then TypeNr:=TypeNr_sint32
                else
                if Keyword='sint64' then TypeNr:=TypeNr_sint64
                else
                if Keyword='sfixed32' then TypeNr:=TypeNr_sfixed32
                else
                if Keyword='sfixed64' then TypeNr:=TypeNr_sfixed64
                else
                ;
              'u':
                if Keyword='uint32' then TypeNr:=TypeNr_uint32
                else
                if Keyword='uint64' then TypeNr:=TypeNr_uint64
                else
                ;

              //else ;
            end;
            if TypeNr=0 then R('Invalud map key value type');
            Expect(',');
            if not NextKeyword then R('Map value type expected');
            TypeName:=IntToStr(TypeNr)+':'+Keyword;
            Expect('>');
           end
          else
           begin
            TypeName:='';
            TypeNr:=0;
            case Keyword[1] of
              'b':
                if Keyword='bool' then TypeNr:=TypeNr_bool
                else
                if Keyword='bytes' then TypeNr:=TypeNr_bytes
                else
                ;
              'd':
                if Keyword='double' then TypeNr:=TypeNr_double
                else
                ;
              'f':
                if Keyword='float' then TypeNr:=TypeNr_float
                else
                if Keyword='fixed32' then TypeNr:=TypeNr_fixed32
                else
                if Keyword='fixed64' then TypeNr:=TypeNr_fixed64
                else
                ;
              'i':
                if Keyword='int32' then TypeNr:=TypeNr_int32
                else
                if Keyword='int64' then TypeNr:=TypeNr_int64
                ;
              's':
                if Keyword='string' then TypeNr:=TypeNr_string
                else
                if Keyword='sint32' then TypeNr:=TypeNr_sint32
                else
                if Keyword='sint64' then TypeNr:=TypeNr_sint64
                else
                if Keyword='sfixed32' then TypeNr:=TypeNr_sfixed32
                else
                if Keyword='sfixed64' then TypeNr:=TypeNr_sfixed64
                else
                if Keyword='single' then TypeNr:=TypeNr_float
                else
                ;
              'u':
                if Keyword='uint32' then TypeNr:=TypeNr_uint32
                else
                if Keyword='uint64' then TypeNr:=TypeNr_uint64
                else
                ;

              //else ;
            end;
            if TypeNr=0 then
             begin
              TypeName:=Keyword;
              TypeNr:=TypeNr__typeByName;
              //lookup here? see build output script
             end;

            if (TypeNr=TypeNr_bytes) and (Quant>=Quant_Repeated) then
              R('"repeated bytes" not supported');
           end;

          if NextKeyword then FieldName:=Keyword else R('Identifier expected');
          while TypeNr<>0 do
           begin
            SkipWhiteSpace;
            if CodeI<=CodeL then
             begin
              inc(CodeI);
              case Code[CodeI-1] of
                ';':
                 begin

                  if (Msg.NextKey>=kFirstReservedNumber)
                    and (Msg.NextKey<=kLastReservedNumber) then
                    R('Reserved key value '+IntToStr(Msg.NextKey));
                  if Msg.Extending and ((Msg.NextKey<Msg.ExtensionsLo) or
                    (Msg.NextKey>Msg.ExtensionsHi)) then
                    R('Key value outside of extensions range '+IntToStr(Msg.NextKey));

                  Msg.AddMember(Quant,TypeNr,FieldName,TypeName,DefaultValue);

                  TypeNr:=0;
                 end;
                '=':
                  Msg.NextKey:=NextInt;
                '[':
                 begin
                  NextKeyword;
                  Expect('=');
                  if (Keyword='default') and (Quant=Quant_Optional) then
                    if NextKeyword then
                      DefaultValue:=Keyword
                    else
                     R('Default value expected')
                  else
                  if (Keyword='packed')
                    and (Quant in [Quant_Repeated,Quant_Repeated_Packed]) then
                    if NextKeyword then
                      if Keyword='true' then Quant:=Quant_Repeated_Packed else
                        if Keyword='false' then Quant:=Quant_Repeated else
                          R('Unknown packed value "'+Keyword+'"')
                    else R('Packed value expected')
                  else
                    R('Unknown modifier "'+Keyword+'"');
                  Expect(']');
                 end;
                else R('Expected ";" or "=" or "["');
              end;
             end;
           end;
        end
      else
       begin
        Expect('}');
        if Msg.OneOfName<>'' then
          Msg.OneOfName:='' //continue with message
        else
          Msg:=Msg.Parent;//pop message
       end;
     end

    else //MsgEnum<>nil
     begin
      if NextKeyword then
       begin
        if Keyword='option' then
         begin
          if not NextKeyword then R('Enum option identifier expected');
          if Keyword='allow_alias' then
           begin
            SkipWhiteSpace;
            if (CodeI<=CodeL) and (Code[CodeI]='=') then
             begin
              inc(CodeI);
              if not NextKeyword then R('Enum option value expected');
              if Keyword='true' then //TODO: allow_alias=true
              else
              if Keyword='false' then //TODO: allow_alias=false
              else
                R('Unknown enum option value "'+Keyword+'"');
             end
            else
              R('Assignment to "allow_alias" expected');
           end
          else
            R('Unknown enum option "'+Keyword+'"');
         end
        else
         begin
          SkipWhiteSpace;
          if (CodeI<=CodeL) and (Code[CodeI]='=') then
           begin
            inc(CodeI);
            MsgEnum.NextKey:=NextInt;
           end;
          MsgEnum.AddMember(0,0,Keyword,'','');
         end;
        if IsNext('[') then
         begin
          //option(s)
          First:=true;
          while First or IsNext(',') do
           begin
            if First then First:=false;
            if IsNext('(') then
             begin
              if not NextKeyword then R('Option name expected');
              OptionName:=Keyword;
              while IsNext('.') do
               begin
                if not NextKeyword then R('Option name expected');
                OptionName:=OptionName+'.'+Keyword;
               end;
              Expect(')');
             end
            else
             begin
              if not NextKeyword then R('Option name expected');
              OptionName:=Keyword;
             end;
            while IsNext('.') do
             begin
              if not NextKeyword then R('Option name expected');
              OptionName:=OptionName+'.'+Keyword;
             end;
            Expect('=');
            //TODO:OptionName+'='+
            NextStr;
           end;
          Expect(']');
         end;
        Expect(';');
       end
      else
        if IsNext('}') then
         begin
          MsgEnum:=nil; //continue
          if Msg<>nil then IsNext(';');
         end
        else
          R('Unexpected syntax');
     end;
end;

function TProtocolBufferParser.GenerateUnit(
  Flags:TProtocolBufferParserFlags): string;
var
  MsgI:integer;
  v:TProtocolBufferParserValue;
  f:TProtocolBufferParserFlag;
begin
  //TODO: Flags from options?
  if Values[pbpvUnitName]<>'' then FUnitName:=Values[pbpvUnitName];
  Result:='unit '+FUnitName+';'#13#10#13#10+
    '// ATTENTION:'#13#10+
    '//   This file was auto generated by dpbp '+GetSelfVersion+#13#10+
    '//   https://github.com/stijnsanders/DelphiProtocolBuffer'#13#10+
    '//'#13#10;
  v:=TProtocolBufferParserValue(0);
  while v<>pbpv_Unknown do
   begin
    if Values[v]<>ProtocolBufferParserValueDefaults[v] then
      Result:=Result+'// VALUE: -'+
        ProtocolBufferParserValueName[v][1]+'"'+Values[v]+'"'#13#10;
    inc(v);
   end;
  f:=TProtocolBufferParserFlag(0);
  while f<>pbpf_Unknown do
   begin
    if f in Flags then Result:=Result+'// FLAG: '+
      ProtocolBufferParserFlagName[f]+#13#10;
    inc(f);
   end;

  if not(pbpfDebugData in Flags) then
    Result:=Result+#13#10'{$D-}'#13#10'{$L-}'#13#10;//'{$Y-}'#13#10;?

  //first pass
  for MsgI:=0 to FMsgDescIndex-1 do
   begin
    //TODO: determine dependancy-safe order?
    if FMsgDesc[MsgI] is TProtBufEnumDescriptor then
     begin
      if (pbpfPrependEnumName in Flags) 
        and (FMsgDesc[MsgI].Parent<>nil) then
        FMsgDesc[MsgI].FPasName:=
          FMsgDesc[MsgI].Parent.Name+'_'+FMsgDesc[MsgI].FPasName;
     end
    else
     begin
      if (pbpfPrependNameParent in Flags)
        and (FMsgDesc[MsgI].Parent<>nil) then
        FMsgDesc[MsgI].FPasName:=
          FMsgDesc[MsgI].Parent.Name+'_'+FMsgDesc[MsgI].FPasName;
     end;
   end;

  //interface
  Result:=Result+#13#10+
    'interface'#13#10#13#10+
    'uses Classes, ProtBuf;'#13#10#13#10+
    'type'#13#10;
  for MsgI:=0 to FMsgDescIndex-1 do
    Result:=Result+FMsgDesc[MsgI].GenerateInterface(Self,Flags);

  //implementation
  Result:=Result+'implementation'#13#10#13#10'uses SysUtils;'#13#10#13#10;

  for MsgI:=0 to FMsgDescIndex-1 do
    Result:=Result+FMsgDesc[MsgI].GenerateImplementation(Self,Flags);

  Result:=Result+'end.'#13#10;
end;

function TProtocolBufferParser.MsgDescByName(
  OptParent: TProtBufMessageDescriptor;
  const Name:string):TProtBufMessageDescriptor;
var
  i:integer;
begin
  if OptParent=nil then i:=FMsgDescIndex else
   begin
    //search with Parent set
    i:=0;
    //TODO: ascend over .Parent(s)?
    while (i<FMsgDescIndex) and ((FMsgDesc[i].Parent<>OptParent)
      or (FMsgDesc[i].Name<>Name)) do inc(i);
   end;
  if i=FMsgDescIndex then
   begin
    //not found, search disregarding parent
    i:=0;
    while (i<FMsgDescIndex) and (FMsgDesc[i].Name<>Name) do inc(i);
   end;
  if i<FMsgDescIndex then Result:=FMsgDesc[i] else Result:=nil;
end;

function IsReservedWord(x:string):boolean;
const
  ResWordsCount=65;
  ResWords:array[0..ResWordsCount-1] of string=(
    'and', 'array', 'as', 'asm',
    'begin', 'case', 'class', 'const',
    'constructor', 'destructor', 'dispinterface', 'div',
    'do', 'downto', 'else', 'end',
    'except', 'exports', 'file', 'finalization',
    'finally', 'for', 'function', 'goto',
    'if', 'implementation', 'in', 'inherited',
    'initialization', 'inline', 'interface', 'is',
    'label', 'library', 'mod', 'nil',
    'not', 'object', 'of', 'or',
    'out', 'packed', 'procedure', 'program',
    'property', 'raise', 'record', 'repeat',
    'resourcestring', 'set', 'shl', 'shr',
    'string', 'then', 'threadvar', 'to',
    'try', 'type', 'unit', 'until',
    'uses', 'var', 'while', 'with',
    'xor'
  );
  ResWordMaxLength:array['A'..'Z'] of byte=(5,5,11,13,7,12,4,0,14,0,0,7,3,3,6,9,0,14,6,9,5,3,5,3,0,0);
var
  c:char;
  y:string;
  i:integer;
begin
  //assert x<>''
  c:=char(UpCase(x[1]));
  //skip anything longer than longest word
  if not(c in ['A'..'Z']) or (Length(x)>ResWordMaxLength[c]) then
    Result:=false
  else
   begin
    y:=LowerCase(x);
    i:=0;
    while (i<ResWordsCount) and (y<>ResWords[i]) do inc(i);
    Result:=i<ResWordsCount;
   end;
end;

procedure TProtocolBufferParser.ListDescriptors(const List: TStrings);
var
  i:integer;
begin
  for i:=0 to FMsgDescIndex-1 do
    //if not(FMsgDesc[i] is TProtBufEnumDescriptor) then
    if FMsgDesc[i].Parent=nil then
      List.AddObject(FMsgDesc[i].FName,FMsgDesc[i]);
end;

{ TProtBufMessageDescriptor }

constructor TProtBufMessageDescriptor.Create(const Name: string);
begin
  inherited Create;
  FName:=Name;
  if IsReservedWord(Name) then
    FPasName:=Name+'_'
  else
    FPasName:=Name;
  FMembersIndex:=0;
  FMembersCount:=0;
  Parent:=nil;
  NextKey:=1;
  OneOfName:='';//used by parser only
  Forwarded:=false;
  Extending:=false;
  ExtensionsLo:=0;
  ExtensionsHi:=0;
end;

procedure TProtBufMessageDescriptor.AddMember(Quant,TypeNr:integer;
  const Name,TypeName,DefaultValue:string);
var
  i:integer;
begin
  i:=0;
  while (i<FMembersIndex) and (FMembers[i].Key<>NextKey) do inc(i);
  if (i<FMembersIndex) then
    raise EProtocolBufferParseError.CreateFmt(
      'Duplicate Key %d in %s',[NextKey,FName]);
  if FMembersIndex=FMembersCount then
   begin
    inc(FMembersCount,32);//Grow
    SetLength(FMembers,FMembersCount);
   end;
  FMembers[FMembersIndex].Key:=NextKey;
  FMembers[FMembersIndex].Quant:=Quant;
  FMembers[FMembersIndex].TypeNr:=TypeNr;
  FMembers[FMembersIndex].Name:=Name;
  FMembers[FMembersIndex].TypeName:=TypeName;
  FMembers[FMembersIndex].DefaultValue:=DefaultValue;
  FMembers[FMembersIndex].OneOfName:=OneOfName;
  inc(FMembersIndex);
  inc(NextKey);
end;

function TProtBufMessageDescriptor.GenerateInterface(
  p:TProtocolBufferParser; Flags:TProtocolBufferParserFlags): string;
var
  i,w:integer;
  m:TProtBufMessageDescriptor;
  s:string;
begin
  Result:='';
  FHighKey:=0;
  FWireFlags:=0;
  for i:=0 to FMembersIndex-1 do
   begin
    if IsReservedWord(FMembers[i].Name) then
      FMembers[i].Name:=FMembers[i].Name+'_';
    if FMembers[i].Key>FHighKey then
      FHighKey:=FMembers[i].Key;
    case FMembers[i].TypeNr of
      TypeNr_string:  FMembers[i].PascalType:='string';//? UTF8?
      TypeNr_int32:   FMembers[i].PascalType:='integer';
      TypeNr_int64:   FMembers[i].PascalType:='int64';
      TypeNr_uint32:  FMembers[i].PascalType:='cardinal';
      TypeNr_uint64:  FMembers[i].PascalType:='int64';//uint64?
      TypeNr_sint32:  FMembers[i].PascalType:='integer';//LongWord?
      TypeNr_sint64:  FMembers[i].PascalType:='int64';//LongLongWord?
      TypeNr_fixed32: FMembers[i].PascalType:='cardinal';//?
      TypeNr_fixed64: FMembers[i].PascalType:='int64';
      TypeNr_sfixed32:FMembers[i].PascalType:='integer';//?
      TypeNr_sfixed64:FMembers[i].PascalType:='int64';
      TypeNr_float:   FMembers[i].PascalType:='single';
      TypeNr_double:  FMembers[i].PascalType:='double';
      TypeNr_bool:    FMembers[i].PascalType:='boolean';
      TypeNr_bytes:   FMembers[i].PascalType:='array of byte';//TBytes?
      //TypeNr_enum:
      //TypeNr_msg:
      TypeNr__typeByName:
       begin
        m:=p.MsgDescByName(Self,FMembers[i].TypeName);
        if m=nil then raise Exception.Create(
          'Descriptor "'+FMembers[i].TypeName+'" not found');
        FMembers[i].PascalType:=p.Values[pbpvTypePrefix]+m.PasName;
        if m is TProtBufEnumDescriptor then
         begin
          FMembers[i].TypeNr:=TypeNr_enum;
          if FMembers[i].DefaultValue<>'' then
           begin
            if pbpfPrependEnumName in Flags then
              FMembers[i].DefaultValue:=
                m.PasName+'_'+FMembers[i].DefaultValue;
           end;
         end
        else
         begin
          FMembers[i].TypeNr:=TypeNr_msg;
          FWireFlags:=FWireFlags or WireFlag_Msg;
          if FMembers[i].Quant>=Quant_Repeated then
            FWireFlags:=FWireFlags or (WireFlag_Msg shl 8)
          else
            FWireFlags:=FWireFlags or WireFlag_Default;
          if not m.Forwarded then
           begin
            m.Forwarded:=true;
            Result:=Result+'  '+p.Values[pbpvTypePrefix]+m.PasName+
              ' = class; //forward'#13#10#13#10;
           end;
         end;
       end;
      TypeNr__map:FMembers[i].PascalType:='TMap<'+FMembers[i].TypeName+'>';//TODO:
      else FMembers[i].PascalType:='???';
    end;
    if (FMembers[i].Quant=Quant_Optional) and (FMembers[i].DefaultValue='') then
      case FMembers[i].TypeNr of
        TypeNr_int32,TypeNr_uint32,TypeNr_sint32,
        TypeNr_int64,TypeNr_uint64,TypeNr_sint64:
          FMembers[i].DefaultValue:='0';
        TypeNr_bool:FMembers[i].DefaultValue:='false';
        TypeNr_enum:FMembers[i].DefaultValue:=
          p.Values[pbpvTypePrefix]+FMembers[i].TypeName+'(0)';
        TypeNr_fixed32,TypeNr_sfixed32,
        TypeNr_fixed64,TypeNr_sfixed64,
        TypeNr_float,TypeNr_double:
          FMembers[i].DefaultValue:='0.0';
      end;
    w:=FMembers[i].TypeNr shr 4;
    FWireFlags:=FWireFlags or (1 shl w);
    if FMembers[i].Quant>=Quant_Repeated then
      FWireFlags:=FWireFlags or (WireFlag_RepeatBase shl w);
    if FMembers[i].DefaultValue<>'' then
      FWireFlags:=FWireFlags or WireFlag_Default;
   end;

  Forwarded:=true;
  Result:=Result+'  '+p.Values[pbpvTypePrefix]+
    FPasName+' = class(TProtocolBufferMessage)'#13#10+
    '  private'#13#10;
  for i:=0 to FMembersIndex-1 do
    if FMembers[i].Quant<Quant_Repeated then
      Result:=Result+'    F'+FMembers[i].Name+
        ': '+FMembers[i].PascalType+';'#13#10
    else
      Result:=Result+'    F'+FMembers[i].Name+
        ': array of '+FMembers[i].PascalType+';'#13#10;

  for i:=0 to FMembersIndex-1 do
    if FMembers[i].Quant>=Quant_Repeated then
     begin
      if FMembers[i].TypeNr in [TypeNr_string,TypeNr_bytes] then
        s:='const ' else s:='';
      Result:=Result+'    function Get'+FMembers[i].Name+
        '(Index: integer): '+FMembers[i].PascalType+';'#13#10+
        '    procedure Set'+FMembers[i].Name+
        '(Index: integer; '+s+'Value: '+FMembers[i].PascalType+');'#13#10+
        '    function Get'+FMembers[i].Name+'Count: integer;'#13#10;
     end;

  Result:=Result+'  protected'#13#10;
  if (FWireFlags and WireFlag_Default)<>0 then
    Result:=Result+'    procedure SetDefaultValues; override;'#13#10;
  if (FWireFlags and WireFlag_VarInt)<>0 then
    Result:=Result+'    procedure ReadVarInt(Stream: TStream; '+
      'Key: TProtocolBufferKey); override;'#13#10;
  if (FWireFlags and WireFlag_Len)<>0 then
    Result:=Result+'    procedure ReadLengthDelim(Stream: TStream; '+
      'Key: TProtocolBufferKey); override;'#13#10;
  if (FWireFlags and WireFlag_32)<>0 then
    Result:=Result+'    procedure ReadFixed32(Stream: TStream; '+
      'Key: TProtocolBufferKey); override;'#13#10;
  if (FWireFlags and WireFlag_64)<>0 then
    Result:=Result+'    procedure ReadFixed64(Stream: TStream; '+
      'Key: TProtocolBufferKey); override;'#13#10;
  Result:=Result+'    procedure WriteFields(Stream: TStream); override;'#13#10;

  Result:=Result+'  public'#13#10;

  if (FWireFlags and WireFlag_Msg)<>0 then
    Result:=Result+'    destructor Destroy; override;'#13#10;

  for i:=0 to FMembersIndex-1 do
    if FMembers[i].Quant<Quant_Repeated then
     begin
      Result:=Result+
        '    property '+FMembers[i].Name+': '+FMembers[i].PascalType+
        ' read F'+FMembers[i].Name;
      if FMembers[i].Quant=Quant_Optional then
        Result:=Result+' write F'+FMembers[i].Name;
      Result:=Result+';'#13#10;
     end
    else
     begin
      if FMembers[i].TypeNr in [TypeNr_string,TypeNr_bytes] then
        s:='const ' else s:='';
      Result:=Result+
        '    property '+FMembers[i].Name+'[Index: integer]: '+
        FMembers[i].PascalType+' read Get'+FMembers[i].Name+
        ' write Set'+FMembers[i].Name+';'#13#10+
        '    property '+FMembers[i].Name+'Count: integer read Get'+
        FMembers[i].Name+'Count;'#13#10+
        '    procedure '+p.Values[pbpvAddPrefix]+FMembers[i].Name+
        '('+s+'Value: '+FMembers[i].PascalType+');'#13#10;
     end;

  Result:=Result+'  end;'#13#10#13#10;
end;

function TProtBufMessageDescriptor.GenerateImplementation(
  p:TProtocolBufferParser; Flags:TProtocolBufferParserFlags): string;
var
  i:integer;
  s:string;
begin
  Result:='{ '+p.Values[pbpvTypePrefix]+FPasName+' }'#13#10#13#10;
  if (FWireFlags and WireFlag_Default)<>0 then
   begin
    Result:=Result+'procedure '+p.Values[pbpvTypePrefix]+FPasName+'.SetDefaultValues;'#13#10+
      'begin'#13#10;
    for i:=0 to FMembersIndex-1 do
      if (FMembers[i].TypeNr=TypeNr_Msg)
        and (FMembers[i].Quant<Quant_Repeated) then
        if FMembers[i].Quant=Quant_Optional then
          Result:=Result+'  F'+FMembers[i].Name+' := nil;'#13#10
        else
          Result:=Result+'  F'+FMembers[i].Name+' := '+
            FMembers[i].PascalType+'.Create;'#13#10
      else
      if FMembers[i].DefaultValue<>'' then
        case FMembers[i].TypeNr of
          //TypeNr_enum: assert DefaultValue corrected when needed
          TypeNr_string:Result:=Result+'  F'+FMembers[i].Name+
            ' := '''+StringReplace(FMembers[i].DefaultValue,
              '''','''''',[rfReplaceAll])+''';'#13#10;
          else Result:=Result+'  F'+FMembers[i].Name+
            ' := '+FMembers[i].DefaultValue+';'#13#10;
        end;
    Result:=Result+'end;'#13#10#13#10;
   end;
  if (FWireFlags and WireFlag_Msg)<>0 then
   begin
    Result:=Result+'destructor '+p.Values[pbpvTypePrefix]+FPasName+'.Destroy;'#13#10;
    if (FWireFlags and (WireFlag_Msg shl 8))<>0 then
      Result:=Result+'var'#13#10'  i: integer;'#13#10;
    Result:=Result+'begin'#13#10;
    for i:=0 to FMembersIndex-1 do
      if FMembers[i].TypeNr=TypeNr_msg then
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  FreeAndNil(F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10
            +'    FreeAndNil(F'+FMembers[i].Name+'[i]);'#13#10;
    Result:=Result+'end;'#13#10#13#10;
   end;
  if (FWireFlags and WireFlag_VarInt)<>0 then
   begin
    Result:=Result+'procedure '+p.Values[pbpvTypePrefix]+FPasName+
      '.ReadVarInt(Stream: TStream; Key: TProtocolBufferKey);'#13#10;
    if ((FWireFlags shr 8) and WireFlag_VarInt)<>0 then
      Result:=Result+'var'#13#10'  l: integer;'#13#10;
    Result:=Result+'begin'#13#10'  case Key of'#13#10;
    for i:=0 to FMembersIndex-1 do
      case FMembers[i].TypeNr of
        TypeNr_int32:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': ReadUInt(Stream, cardinal(F'+FMembers[i].Name+'));'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadUInt(Stream, cardinal(F'+FMembers[i].Name+'[l]));'#13#10+
              '      end;'#13#10;
        TypeNr_int64,TypeNr_uint32,TypeNr_uint64:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': ReadUInt(Stream, F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadUInt(Stream, F'+FMembers[i].Name+'[l]);'#13#10+
              '      end;'#13#10;
        TypeNr_sint32,TypeNr_sint64:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': ReadSInt(Stream, F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadSInt(Stream, F'+FMembers[i].Name+'[l]);'#13#10+
              '      end;'#13#10;
        TypeNr_bool:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': F'+FMembers[i].Name+' := ReadBool(Stream);'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadBool(Stream, F'+FMembers[i].Name+'[l]);'#13#10+
              '      end;'#13#10;
        TypeNr_enum:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': F'+FMembers[i].Name+' := '+
                p.Values[pbpvTypePrefix]+FMembers[i].TypeName+
                '(ReadEnum(Stream));'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        F'+FMembers[i].Name+'[l] := '+
              p.Values[pbpvTypePrefix]+FMembers[i].TypeName+
              '(ReadEnum(Stream));'#13#10+
              '      end;'#13#10;
      end;
    Result:=Result+'  end;'#13#10'end;'#13#10#13#10;
   end;
  if (FWireFlags and WireFlag_Len)<>0 then
   begin
    Result:=Result+'procedure '+p.Values[pbpvTypePrefix]+FPasName+
      '.ReadLengthDelim(Stream: TStream; Key: TProtocolBufferKey);'#13#10;
    if ((FWireFlags shr 8) and WireFlag_Len)<>0 then
      Result:=Result+'var'#13#10'  l: integer;'#13#10;
    Result:=Result+'begin'#13#10'  case Key of'#13#10;
    for i:=0 to FMembersIndex-1 do
      case FMembers[i].TypeNr of
        TypeNr_string:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': ReadStr(Stream, F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadStr(Stream, F'+FMembers[i].Name+'[l]);'#13#10+
              '      end;'#13#10;

        TypeNr_bytes:
          //assert FMembers[i].Quant<Quant_Repeated
          Result:=Result+'    '+IntToStr(FMembers[i].Key)+
            ': ReadBytes(Stream, F'+FMembers[i].Name+');'#13#10;
        TypeNr_msg:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        F'+FMembers[i].Name+':='+
              FMembers[i].PascalType+'.Create;'#13#10+
              '        ReadMessage(Stream, F'+FMembers[i].Name+');'#13#10+
              '      end;'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        F'+FMembers[i].Name+'[l]:='+
              FMembers[i].PascalType+'.Create;'#13#10+
              '        ReadMessage(Stream, F'+FMembers[i].Name+'[l]);'#13#10+
              '      end;'#13#10;
      end;
    Result:=Result+'  end;'#13#10'end;'#13#10#13#10;
   end;
  if (FWireFlags and WireFlag_32)<>0 then
   begin
    Result:=Result+'procedure '+p.Values[pbpvTypePrefix]+FPasName+
      '.ReadFixed32(Stream: TStream; Key: TProtocolBufferKey);'#13#10;
    if ((FWireFlags shr 8) and WireFlag_32)<>0 then
      Result:=Result+'var'#13#10'  l: integer;'#13#10;
    Result:=Result+'begin'#13#10'  case Key of'#13#10;
    for i:=0 to FMembersIndex-1 do
      if FMembers[i].TypeNr in
        [TypeNr_fixed32,TypeNr_sfixed32,TypeNr_float] then
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'    '+IntToStr(FMembers[i].Key)+
            ': ReadBlock(Stream, F'+FMembers[i].Name+', 4);'#13#10
        else
          Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
            '      begin'#13#10+
            '        l := Length(F'+FMembers[i].Name+');'#13#10+
            '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
            '        ReadBlock(Stream, F'+FMembers[i].Name+', 4);'#13#10+
            '      end;'#13#10;
    Result:=Result+'  end;'#13#10'end;'#13#10#13#10;
   end;
  if (FWireFlags and WireFlag_64)<>0 then
   begin
    Result:=Result+'procedure '+p.Values[pbpvTypePrefix]+FPasName+
      '.ReadFixed64(Stream: TStream; Key: TProtocolBufferKey);'#13#10;
    if ((FWireFlags shr 8) and WireFlag_64)<>0 then
      Result:=Result+'var'#13#10'  l: integer;'#13#10;
    Result:=Result+'begin'#13#10'  case Key of'#13#10;
    for i:=0 to FMembersIndex-1 do
      if FMembers[i].TypeNr in
        [TypeNr_fixed64,TypeNr_sfixed64,TypeNr_double] then
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'    '+IntToStr(FMembers[i].Key)+
            ': ReadBlock(Stream, F'+FMembers[i].Name+', 8);'#13#10
        else
          Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
            '      begin'#13#10+
            '        l := Length(F'+FMembers[i].Name+');'#13#10+
            '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
            '        ReadBlock(Stream, F'+FMembers[i].Name+', 8);'#13#10+
            '      end;'#13#10;
    Result:=Result+'  end;'#13#10'end;'#13#10#13#10;
   end;

  Result:=Result+'procedure '+p.Values[pbpvTypePrefix]+FPasName+
    '.WriteFields(Stream: TStream);'#13#10;
  if (FWireFlags and $FF00)<>0 then
    Result:=Result+'var'#13#10'  i: integer;'#13#10;
  Result:=Result+'begin'#13#10;
  for i:=0 to FMembersIndex-1 do
    case FMembers[i].TypeNr of
      TypeNr_int32,TypeNr_int64,TypeNr_uint32,TypeNr_uint64:
        if FMembers[i].Quant<Quant_Repeated then
          if FMembers[i].DefaultValue='' then
            Result:=Result+'  WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'  if F'+FMembers[i].Name+'<>'+
              FMembers[i].DefaultValue+' then'#13#10+
              '    WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i]);'#13#10;
      TypeNr_sint32,TypeNr_sint64:
        if FMembers[i].Quant<Quant_Repeated then
          if FMembers[i].DefaultValue='' then
            Result:=Result+'  WriteSInt(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'  if F'+FMembers[i].Name+'<>'+
              FMembers[i].DefaultValue+' then'#13#10+
              '    WriteSInt(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteSInt(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i]);'#13#10;
      TypeNr_bool:
        if FMembers[i].Quant<Quant_Repeated then
          if FMembers[i].DefaultValue='' then
            Result:=Result+'  if F'+FMembers[i].Name+
              ' then WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+', 1)'#13#10+
              '    else WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+', 0);'#13#10
          else
            if LowerCase(FMembers[i].DefaultValue)='true' then
              Result:=Result+'  if not F'+FMembers[i].Name+' then'#13#10+
                '    WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+', 0);'#13#10
            else
              Result:=Result+'  if F'+FMembers[i].Name+' then'#13#10+
                '    WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+', 1);'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    if F'+FMembers[i].Name+
            '[i] then WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+', 1)'#13#10+
            '      else WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+', 0);'#13#10;
      TypeNr_string:
        if FMembers[i].Quant<Quant_Repeated then
          if FMembers[i].DefaultValue='' then
            Result:=Result+'  WriteStr(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'  if F'+FMembers[i].Name+'<>'+
              FMembers[i].DefaultValue+' then'#13#10+
              '    WriteStr(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteStr(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i]);'#13#10;
      TypeNr_bytes:
        //assert FMembers[i].Quant<Quant_Repeated
        //assert FMembers[i].DefaultValue=''
        Result:=Result+'  WriteBytes(Stream, '+IntToStr(FMembers[i].Key)+
          ', F'+FMembers[i].Name+');'#13#10;
      TypeNr_fixed32,TypeNr_sfixed32,TypeNr_float:
        if FMembers[i].Quant<Quant_Repeated then
          if FMembers[i].DefaultValue='' then
            Result:=Result+'  WriteBlock(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+', 4);'#13#10
          else
            Result:=Result+'  if F'+FMembers[i].Name+'<>'+
              FMembers[i].DefaultValue+' then'#13#10+
              '    WriteBlock(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+', 4);'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteBlock(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i], 4);'#13#10;
      TypeNr_fixed64,TypeNr_sfixed64,TypeNr_double:
        if FMembers[i].Quant<Quant_Repeated then
          if FMembers[i].DefaultValue='' then
            Result:=Result+'  WriteBlock(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+', 8);'#13#10
          else
            Result:=Result+'  if F'+FMembers[i].Name+'<>'+
              FMembers[i].DefaultValue+' then'#13#10+
              '    WriteBlock(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+', 8);'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteBlock(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i], 8);'#13#10;
      TypeNr_enum:
        if FMembers[i].Quant<Quant_Repeated then
          if FMembers[i].DefaultValue='' then
            Result:=Result+'  WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+
              ', cardinal(F'+FMembers[i].Name+'));'#13#10
          else
            Result:=Result+'  if F'+FMembers[i].Name+'<>'+
              FMembers[i].DefaultValue+' then'#13#10+
              '    WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+
              ', cardinal(F'+FMembers[i].Name+'));'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+
            ', cardinal(F'+FMembers[i].Name+'[i]));'#13#10;
      TypeNr_msg:
        //assert FMembers[i].DefaultValue=''
        if FMembers[i].Quant<Quant_Repeated then
          if FMembers[i].Quant=Quant_Optional then
            Result:=Result+'  if F'+FMembers[i].Name+'<>nil then'#13#10+
              '    WriteMessage(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'  WriteMessage(Stream, '+IntToStr(FMembers[i].Key)+
              ', F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            //'    if F'+FMembers[i].Name+'<>nil then'#13#10+
            '    WriteMessage(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i]);'#13#10;
    end;
  Result:=Result+'end;'#13#10#13#10;

  for i:=0 to FMembersIndex-1 do
   begin
    if FMembers[i].TypeNr in [TypeNr_string,TypeNr_bytes] then
      s:='const ' else s:='';
    if FMembers[i].Quant>=Quant_Repeated then
      Result:=Result+
        'function '+p.Values[pbpvTypePrefix]+FPasName+'.Get'+FMembers[i].Name+
          '(Index: integer): '+FMembers[i].PascalType+';'#13#10+
        'begin'#13#10+
        '  Result := F'+FMembers[i].Name+'[Index];'#13#10+
        'end;'#13#10#13#10+
        'procedure '+p.Values[pbpvTypePrefix]+FPasName+'.Set'+FMembers[i].Name+
          '(Index: integer; '+s+'Value: '+FMembers[i].PascalType+');'#13#10+
        'begin'#13#10+
        '  F'+FMembers[i].Name+'[Index] := Value;'#13#10+
        'end;'#13#10#13#10+
        'function '+p.Values[pbpvTypePrefix]+FPasName+'.Get'+FMembers[i].Name+
          'Count: integer;'#13#10+
        'begin'#13#10+
        '  Result := Length(F'+FMembers[i].Name+');'#13#10+
        'end;'#13#10#13#10+
        'procedure '+p.Values[pbpvTypePrefix]+FPasName+'.'+
          p.Values[pbpvAddPrefix]+FMembers[i].Name+
          '('+s+'Value: '+FMembers[i].PascalType+');'#13#10+
        'var'#13#10+
        '  l: integer;'#13#10+
        'begin'#13#10+
        '  l := Length(F'+FMembers[i].Name+');'#13#10+
        '  SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
        '  F'+FMembers[i].Name+'[l] := Value;'#13#10+
        'end;'#13#10#13#10;
   end;
end;

function TProtBufMessageDescriptor.MemberByKey(Key: integer;
  var FieldName, FieldType: string; var Quant, TypeNr: integer): boolean;
var
  i:integer;
begin
  i:=0;
  while (i<FMembersIndex) and (FMembers[i].Key<>Key) do inc(i);
  if i=FMembersIndex then Result:=false else
   begin
    FieldName:=FMembers[i].Name;
    FieldType:=FMembers[i].TypeName;
    Quant:=FMembers[i].Quant;
    TypeNr:=FMembers[i].TypeNr;
    Result:=true;
   end;
end;

{ TProtBufEnumDescriptor }

function TProtBufEnumDescriptor.GenerateInterface(p:TProtocolBufferParser;
  Flags:TProtocolBufferParserFlags): string;
var
  i,k:integer;
  b:boolean;
  m:string;
begin
  //TODO: switch between enum, const
  Result:='  '+p.Values[pbpvTypePrefix]+FPasName+' = ('#13#10'    ';
  b:=true;
  k:=0;
  //TODO: switch prefix enum items with enum name?
  for i:=0 to FMembersIndex-1 do
   begin
    if b then b:=false else Result:=Result+','#13#10'    ';
    m:=FMembers[i].Name;
    if pbpfPrependEnumFields in Flags then m:=FPasName+'_'+m;//:=FName+'_'+m;?
    if k=FMembers[i].Key then
     begin
      Result:=Result+m;
     end
    else
     begin
      k:=FMembers[i].Key;
      if k>100000 then
        Result:=Result+m+' = $'+IntToHex(k,8)
      else
        Result:=Result+m+' = '+IntToStr(k);
     end;
    inc(k);
   end;
  Result:=Result+#13#10'  );'#13#10#13#10;
end;

function TProtBufEnumDescriptor.GenerateImplementation(
  p:TProtocolBufferParser; Flags:TProtocolBufferParserFlags): string;
begin
  Result:='';
end;

end.

