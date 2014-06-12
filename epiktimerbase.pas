unit EpikTimerBase;

{$IFDEF FPC}
  {$MODE DELPHI}{$H+}
{$ENDIF}


interface

uses
  {$IFDEF Windows}
    Windows, MMSystem,
  {$ELSE}
      unix,
//      unixutil,
     baseunix ,
  {$ENDIF}
  EpikTimer,
  Classes, SysUtils;

//function newGetTickCount: Cardinal;
function GetTicks: TickType;
function GetTicksFrequency: TickType;
procedure InitTimebases(var HWCapabilityDataAvailable,
                            HWTickSupportAvailable,
                            MicrosecondSystemClockAvailable : Boolean;
                        var TimebaseData                    : TimebaseData;
                        var StartupCorrelationSample, UpdatedCorrelationSample: TimebaseCorrelationData);
procedure CorrelateTimebases(HWtickSupportAvailable, MicrosecondSystemClockAvailable: Boolean;
                             var TimebaseData                                      : TimebaseData;
                             var StartupCorrelationSample, UpdatedCorrelationSample: TimebaseCorrelationData);
function GetTimebaseCorrelation(HWtickSupportAvailable: Boolean; var StartupCorrelationSample, UpdatedCorrelationSample: TimebaseCorrelationData): TickType;
function CalibrateTickFrequency(var TimeBase: TimebaseData): Integer;
function CalibrateCallOverheads(var TimeBase: TimebaseData): Integer;
procedure GetCorrelationSample(var CorrelationData: TimeBaseCorrelationData);
function SystemSleep(Milliseconds: Integer): integer;

implementation

Type
  TpTimeSpec = ^Ttimespec;

var
  EpikTimerBaseStartupCorrelationSample: TimebaseCorrelationData;               // Starting ticks correlation snapshot
  EpikTimerBaseUpdatedCorrelationSample: TimebaseCorrelationData;
  EpikTimerBaseTimebaseData: TimebaseData;                                      // The hardware timebase
//  EpikTimerBaseTimebaseCalibrationParameters: TimebaseCalibrationParameters;    // Calibration data for this timebase
  EpikTimerBaseHWCapabilityDataAvailable: Boolean;                              // True if hardware tick support is available
  EpikTimerBaseHWTickSupportAvailable: Boolean;                                 // True if hardware tick support is available
  EpikTimerBaseMicrosecondSystemClockAvailable:Boolean; // true if system has microsecond clock










  {$IFDEF CPUI386}
  { Some references for this section can be found at:
        http://www.sandpile.org/ia32/cpuid.htm
        http://www.sandpile.org/ia32/opc_2.htm
        http://www.sandpile.org/ia32/msr.htm
  }

  // Pentium specific... push and pop the flags and check for CPUID availability
  function HasHardwareCapabilityData: Boolean;
  begin
    asm
     PUSHFD
     POP    EAX
     MOV    EDX,EAX
     XOR    EAX,$200000
     PUSH   EAX
     POPFD
     PUSHFD
     POP    EAX
     XOR    EAX,EDX
     JZ     @EXIT
     MOV    AL,TRUE
     @EXIT:
    end;
  end;

  function HasHardwareTickCounter: Boolean;
    var FeatureFlags: Longword;
    begin
      FeatureFlags:=0;
      asm
        PUSH   EBX
        XOR    EAX,EAX
        DW     $A20F
        POP    EBX
        CMP    EAX,1
        JL     @EXIT
        XOR    EAX,EAX
        MOV    EAX,1
        PUSH   EBX
        DW     $A20F
        MOV    FEATUREFLAGS,EDX
        POP    EBX
        @EXIT:
      end;
      Result := (FeatureFlags and $10) <> 0;
    end;

  // Execute the Pentium's RDTSC instruction to access the counter value.
  function HardwareTicks: TickType; assembler; asm DW 0310FH end;

  (* * * * * * * * End of i386 Hardware specific code  * * * * * * *)


  // These are here for architectures that don't have a precision hardware
  // timing source. They'll return zeros for overhead values. The timers
  // will work but there won't be any error compensation for long
  // term accuracy.
  {$ELSE} // add other architectures and hardware specific tick sources here
  function HasHardwareCapabilityData: Boolean; begin Result:=False end;
  function HasHardwareTickCounter: Boolean; begin Result:=false end;
  function HardwareTicks:TickType; begin result:=0 end;
  {$ENDIF}



function clock_gettime(monolitic: Integer; ts: TpTimeSpec): Integer;
begin
  Result := 0;
end;

function GetHardwareTicks: TickType;
const
  CLOCK_MONOTONIC = 1;
  NanoPerSec = 1000000000;
var
  ts: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @ts);
  Result := ts.tv_sec;
  Result := (Result*NanoPerSec) + ts.tv_nsec;
end;

function GetTicks: TickType;
begin
  Result := EpikTimerBaseTimebaseData.Ticks;
end;

function GetTicksFrequency: TickType;
begin
  Result := EpikTimerBaseTimebaseData.TicksFrequency;
end;


{ Experimental, no idea if this works or is implemented correctly }
function newGetTickCount: Cardinal;
const
  CLOCK_MONOTONIC = 1;
  NanoPerMilli = 1000000;
  MilliPerSec = 1000;
var
  ts: TTimeSpec;
  i: TickType;
  t: timeval;
begin
  // use the Posix clock_gettime() call
  if clock_gettime(CLOCK_MONOTONIC, @ts)=0 then
  begin
    // Use the FPC fallback
    fpgettimeofday(@t,nil);
    // Build a 64 bit microsecond tick from the seconds and microsecond longints
    Result := (TickType(t.tv_sec) * NanoPerMilli) + t.tv_usec;
    Exit;
  end;
  i := ts.tv_sec;
  i := (i*MilliPerSec) + ts.tv_nsec div NanoPerMilli;
  Result := i;
end;


function SystemSleep(Milliseconds: Integer): integer;
{$IFDEF Windows}

begin
  Sleep(Milliseconds);
  Result := 0;
end;

{$ELSE}

  {$IFDEF CPUX86_64}

begin
  Sleep(Milliseconds);
  Result := 0;
end;

  {$ELSE}

var
  timerequested, timeremaining: timespec;
begin
  // This is not a very accurate or stable gating source... but it's the
  // only one that's available for making short term measurements.
  timerequested.tv_sec:=Milliseconds div 1000;
  timerequested.tv_nsec:=(Milliseconds mod 1000) * 1000000;
  Result := fpnanosleep(@timerequested, @timeremaining) // returns 0 if ok
end;

  {$ENDIF}

{$ENDIF}

function NullHardwareTicks:TickType; begin Result:=0 end;

(* * * * * * * * * * Timebase calibration section  * * * * * * * * * *)

// Grab a snapshot of the system and hardware tick sources... as quickly as
// possible and with overhead compensation. These samples will be used to
// correct the accuracy of the hardware tick frequency source when precision
// long term measurements are desired.
procedure GetCorrelationSample(var CorrelationData: TimeBaseCorrelationData);
Var
  TicksHW, TicksSys: TickType;
  THW, TSYS: TickCallFunc;
begin
  THW:=EpikTimerBaseTimebaseData.Ticks; TSYS:=EpikTimerBaseTimebaseData.Ticks;
  TicksHW:=THW(); TicksSys:=TSYS();
  With CorrelationData do
    Begin
      SystemTicks:= TicksSys - EpikTimerBaseTimebaseData.TicksOverhead(*-FSystemTicks.TicksOverhead*) ;
      HWTicks:=TicksHW-EpikTimerBaseTimebaseData.TicksOverhead;
    End
end;


// Set up compensation for call overhead to the Ticks and SystemSleep functions.
// The Timebase record contains Calibration parameters to be used for each
// timebase source. These have to be unique as the output of this measurement
// is measured in "ticks"... which are different periods for each timebase.

function CalibrateCallOverheads(var TimeBase: TimebaseData): Integer;
var i:Integer; St,Fin,Total:TickType;
begin
  with Timebase, Timebase.CalibrationParms do
  begin
    Total:=0; Result:=1;
    for I:=1 to TicksIterations do // First get the base tick getting overhead
      begin
        St:=Ticks(); Fin:=Ticks();
        Total:=Total+(Fin-St); // dump the first sample
      end;
    TicksOverhead:=Total div TicksIterations;
    Total:=0;
    For I:=1 to SleepIterations do
    Begin
      St:=Ticks();
      if SystemSleep(0)<>0 then exit;
      Fin:=Ticks();
      Total:=Total+((Fin-St)-TicksOverhead);
    End;
    SleepOverhead:=Total div SleepIterations;
    OverheadCalibrated:=True; Result:=0
  End
end;

// CalibrateTickFrequency is a fallback in case a microsecond resolution system
// clock isn't found. It's still important because the long term accuracy of the
// timers will depend on the determination of the tick frequency... in other words,
// the number of ticks it takes to make a second. If this measurement isn't
// accurate, the counters will proportionately drift over time.
//
// The technique used here is to gate a sample of the tick stream with a known
// time reference which, in this case, is nanosleep. There is a *lot* of jitter
// in a nanosleep call so an attempt is made to compensate for some of it here.

function CalibrateTickFrequency(var TimeBase: TimebaseData): Integer;
var
  i: Integer;
  Total, SS, SE: TickType;
  ElapsedTicks, SampleTime: Extended;
begin
  With Timebase, Timebase.CalibrationParms do
  Begin
    Result:=1; //maintain unitialized default in case something goes wrong.
    Total:=0;
    For i:=1 to FreqIterations do
      begin
        SS:=Ticks();
        SystemSleep(FrequencyGateTimeMS);
        SE:=Ticks();
        Total:=Total+((SE-SS)-(SleepOverhead+TicksOverhead))
      End;
    //doing the floating point conversion allows SampleTime parms of < 1 second
    ElapsedTicks:=Total div FreqIterations;
    SampleTime:=FrequencyGateTimeMS;

    TicksFrequency:=Trunc( ElapsedTicks / (SampleTime / 1000));

    FreqCalibrated:=True;
  end;
end;

(* * * * * * * * * * Timebase correlation section  * * * * * * * * * *)

{ Get another snapshot of the system and hardware tick sources and compute a
  corrected value for the hardware frequency. In a short amount of time, the
  microsecond system clock accumulates enough ticks to perform a *very*
  accurate frequency measurement of the typically picosecond time stamp counter. }

function GetTimebaseCorrelation(HWtickSupportAvailable: Boolean; var StartupCorrelationSample, UpdatedCorrelationSample: TimebaseCorrelationData): TickType;
Var
  HWDiff, SysDiff, Corrected: Extended;
begin
  If HWtickSupportAvailable then
    Begin
      GetCorrelationSample(UpdatedCorrelationSample);
      HWDiff:=UpdatedCorrelationSample.HWTicks-StartupCorrelationSample.HWTicks;
      SysDiff:=UpdatedCorrelationSample.SystemTicks-StartupCorrelationSample.SystemTicks;
      Corrected:=HWDiff / (SysDiff / DefaultSystemTicksPerSecond);
      Result:=trunc(Corrected)
    End
  else result:=0
end;



{ If an accurate reference is available, update the TicksFrequency of the
  hardware timebase. }
procedure CorrelateTimebases(HWtickSupportAvailable, MicrosecondSystemClockAvailable: Boolean;
                             var TimebaseData                                      : TimebaseData;
                             var StartupCorrelationSample, UpdatedCorrelationSample: TimebaseCorrelationData);
begin
  If MicrosecondSystemClockAvailable and HWTickSupportAvailable then
    TimebaseData.TicksFrequency:=GetTimebaseCorrelation(HWtickSupportAvailable, StartupCorrelationSample, UpdatedCorrelationSample);
end;



procedure InitTimebases(var HWCapabilityDataAvailable,
                            HWTickSupportAvailable,
                            MicrosecondSystemClockAvailable : Boolean;
                        var TimebaseData                    : TimebaseData;
                        var StartupCorrelationSample, UpdatedCorrelationSample: TimebaseCorrelationData);
Begin
  { Tick frequency rates are different for the system and HW timebases so we
    need to store calibration data in the period format of each one. }
  With TimebaseData.CalibrationParms do
    Begin
      FreqCalibrated:=False;
      OverheadCalibrated:=False;
      TicksIterations:=5;
      SleepIterations:=10;
      FrequencyGateTimeMS:=100;
      FreqIterations:=1;
    End;

  // Initialize the HW tick source data
  HWCapabilityDataAvailable:=False;
  HWTickSupportAvailable:=False;
  TimebaseData.Ticks:=@NullHardwareTicks; // returns a zero if no HW support
  TimebaseData.TicksFrequency:=1;
  With TimebaseData.CalibrationParms do
    Begin
      FreqCalibrated:=False;
      OverheadCalibrated:=False;
      TicksIterations:=10;
      SleepIterations:=20;
      FrequencyGateTimeMS:=150;
      FreqIterations:=1;
    End;

  if HasHardwareCapabilityData then
    Begin
      HWCapabilityDataAvailable:=True;
      If HasHardwareTickCounter then
        Begin
          TimebaseData.Ticks:=@HardwareTicks;
          HWTickSupportAvailable:=CalibrateCallOverheads(TimebaseData)=0
        End
    end;

  CalibrateCallOverheads(TimebaseData);
  CalibrateTickFrequency(TimebaseData);

  // Overheads are set... get starting timestamps for long term calibration runs
  GetCorrelationSample(StartupCorrelationSample);
  With TimeBaseData do
    If (TicksFrequency>(DefaultSystemTicksPerSecond-SystemTicksNormalRangeLimit)) and
      (TicksFrequency<(DefaultSystemTicksPerSecond+SystemTicksNormalRangeLimit)) then
      Begin // We've got a good microsecond system clock
        TimeBaseData.TicksFrequency:=DefaultSystemTicksPerSecond; // assume it's pure
        MicrosecondSystemClockAvailable:=True;
        If HWTickSupportAvailable then
          Begin
            SystemSleep(TimebaseData.CalibrationParms.FrequencyGateTimeMS); // rough gate
            CorrelateTimebases(HWCapabilityDataAvailable, MicrosecondSystemClockAvailable,
                               TimebaseData, StartupCorrelationSample, UpdatedCorrelationSample);
          End
      end
    else
      Begin
        MicrosecondSystemClockAvailable:=False;
        If HWTickSupportAvailable then
          CalibrateTickFrequency(TimebaseData) // sloppy but usable fallback calibration
      End;
End;


initialization
begin
  InitTimebases(EpikTimerBaseHWCapabilityDataAvailable,
                EpikTimerBaseHWTickSupportAvailable,
                EpikTimerBaseMicrosecondSystemClockAvailable,
                EpikTimerBaseTimebaseData,
                EpikTimerBaseStartupCorrelationSample,
                EpikTimerBaseUpdatedCorrelationSample);
end;

end.

