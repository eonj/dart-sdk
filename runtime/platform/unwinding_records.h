// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
// Class for patching compiled code.

#ifndef RUNTIME_PLATFORM_UNWINDING_RECORDS_H_
#define RUNTIME_PLATFORM_UNWINDING_RECORDS_H_

#include "platform/allocation.h"

namespace dart {

class UnwindingRecordsPlatform : public AllStatic {
 public:
  static intptr_t SizeInBytes();

  static void RegisterExecutableMemory(void* start,
                                       intptr_t size,
                                       void** pp_dynamic_table);
  static void RegisterExecutableMemory(void* start,
                                       intptr_t size,
                                       void* records_start,
                                       void** pp_dynamic_table);
  static void UnregisterDynamicTable(void* p_dynamic_table);
};

#if defined(DART_HOST_OS_WINDOWS) && defined(ARCH_IS_64_BIT) &&                \
    (!defined(DART_PRECOMPILER) || defined(TESTING))
#define NEED_WINDOWS_UNWINDING_RECORDS 1
// Guard for code and definitions that are used when the 64-bit Windows runtime
// may make calls to the Windows APIs using the unwinding records information.
#define UNWINDING_RECORDS_WINDOWS_HOST 1
#elif defined(DART_TARGET_OS_WINDOWS) && defined(TARGET_ARCH_IS_64_BIT)
#define NEED_WINDOWS_UNWINDING_RECORDS 1
// Guard for code and definitions that are used when precompiling for
// a 64-bit Windows target without any runtime use (and thus, no API calls).
#define UNWINDING_RECORDS_WINDOWS_PRECOMPILER 1
#endif

#if defined(NEED_WINDOWS_UNWINDING_RECORDS)

#pragma pack(push, 1)

#if !defined(DART_HOST_OS_WINDOWS) || !defined(HOST_ARCH_X64)
typedef uint32_t ULONG;
typedef uint32_t DWORD;
#endif

#if defined(TARGET_ARCH_X64)
//
// Refer to https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64
//
typedef unsigned char UBYTE;
typedef uint16_t USHORT;
typedef union _UNWIND_CODE {
  struct {
    UBYTE CodeOffset;
    UBYTE UnwindOp : 4;
    UBYTE OpInfo : 4;
  };
  USHORT FrameOffset;
} UNWIND_CODE, *PUNWIND_CODE;

typedef struct _UNWIND_INFO {
  UBYTE Version : 3;
  UBYTE Flags : 5;
  UBYTE SizeOfProlog;
  UBYTE CountOfCodes;
  UBYTE FrameRegister : 4;
  UBYTE FrameOffset : 4;
  UNWIND_CODE UnwindCode[2];
} UNWIND_INFO, *PUNWIND_INFO;

static constexpr int kPushRbpInstructionLength = 1;
static const int kMovRbpRspInstructionLength = 3;
static constexpr int kRbpPrefixLength =
    kPushRbpInstructionLength + kMovRbpRspInstructionLength;
static constexpr int kRBP = 5;

#ifndef UNW_FLAG_NHANDLER
#define UNW_FLAG_NHANDLER 0
#endif

struct GeneratedCodeUnwindInfo {
  UNWIND_INFO unwind_info;

  GeneratedCodeUnwindInfo() {
    unwind_info.Version = 1;
    unwind_info.Flags = UNW_FLAG_NHANDLER;
    unwind_info.SizeOfProlog = kRbpPrefixLength;
    unwind_info.CountOfCodes = 2;
    unwind_info.FrameRegister = kRBP;
    unwind_info.FrameOffset = 0;
    unwind_info.UnwindCode[0].CodeOffset = kRbpPrefixLength;
    unwind_info.UnwindCode[0].UnwindOp = 3;  // UWOP_SET_FPREG
    unwind_info.UnwindCode[0].OpInfo = 0;
    unwind_info.UnwindCode[1].CodeOffset = kPushRbpInstructionLength;
    unwind_info.UnwindCode[1].UnwindOp = 0;  // UWOP_PUSH_NONVOL
    unwind_info.UnwindCode[1].OpInfo = kRBP;
  }
};

static constexpr uint32_t kUnwindingRecordMagic = 0xAABBCCDD;

struct TargetRuntimeFunction {
  ULONG BeginAddress;
  ULONG EndAddress;
  ULONG UnwindData;
};

struct CodeRangeUnwindingRecord {
  void* dynamic_table;
  uint32_t magic;
  uint32_t runtime_function_count;
  GeneratedCodeUnwindInfo unwind_info;
  intptr_t exception_handler;
  // Must be cast to a PRUNTIME_FUNCTION when passed to Windows APIs.
  TargetRuntimeFunction runtime_function[1];
};

#elif defined(TARGET_ARCH_ARM64)

// ARM64 unwind codes are defined in below doc.
// https://docs.microsoft.com/en-us/cpp/build/arm64-exception-handling#unwind-codes
enum UnwindOp8Bit {
  OpNop = 0xE3,
  OpAllocS = 0x00,
  OpSaveFpLr = 0x40,
  OpSaveFpLrX = 0x80,
  OpSetFp = 0xE1,
  OpAddFp = 0xE2,
  OpEnd = 0xE4,
};

typedef uint32_t UNWIND_CODE;

constexpr UNWIND_CODE Combine8BitUnwindCodes(uint8_t code0 = OpNop,
                                             uint8_t code1 = OpNop,
                                             uint8_t code2 = OpNop,
                                             uint8_t code3 = OpNop) {
  return static_cast<uint32_t>(code0) | (static_cast<uint32_t>(code1) << 8) |
         (static_cast<uint32_t>(code2) << 16) |
         (static_cast<uint32_t>(code3) << 24);
}

// UNWIND_INFO defines the static part (first 32-bit) of the .xdata record in
// below doc.
// https://docs.microsoft.com/en-us/cpp/build/arm64-exception-handling#xdata-records
struct UNWIND_INFO {
  uint32_t FunctionLength : 18;
  uint32_t Version : 2;
  uint32_t X : 1;
  uint32_t E : 1;
  uint32_t EpilogCount : 5;
  uint32_t CodeWords : 5;
};

/**
 * Base on below doc, unwind record has 18 bits (unsigned) to encode function
 * length, besides 2 LSB which are always 0.
 * https://docs.microsoft.com/en-us/cpp/build/arm64-exception-handling#xdata-records
 */
static const int kMaxFunctionLength = ((1 << 18) - 1) << 2;

static constexpr int kDefaultNumberOfUnwindCodeWords = 1;
static constexpr int kMaxExceptionThunkSize = 16;
static constexpr int kFunctionLengthShiftSize = 2;
static constexpr int kFunctionLengthMask = (1 << kFunctionLengthShiftSize) - 1;

// Generate an unwind code for "stp fp, lr, [sp, #pre_index_offset]!".
inline uint8_t MakeOpSaveFpLrX(int pre_index_offset) {
  // See unwind code save_fplr_x in
  // https://docs.microsoft.com/en-us/cpp/build/arm64-exception-handling#unwind-codes
  ASSERT(pre_index_offset <= -8);
  ASSERT(pre_index_offset >= -512);
  constexpr int kShiftSize = 3;
  constexpr int kShiftMask = (1 << kShiftSize) - 1;
  ASSERT((pre_index_offset & kShiftMask) == 0);
  USE(kShiftMask);
  // Solve for Z where -(Z+1)*8 = pre_index_offset.
  int encoded_value = (-pre_index_offset >> kShiftSize) - 1;
  return OpSaveFpLrX | encoded_value;
}

template <int kNumberOfUnwindCodeWords = kDefaultNumberOfUnwindCodeWords>
struct UnwindData {
  UNWIND_INFO unwind_info;
  UNWIND_CODE unwind_codes[kNumberOfUnwindCodeWords];

  UnwindData() {
    memset(&unwind_info, 0, sizeof(UNWIND_INFO));
    unwind_info.X = 0;  // no exception handler
    unwind_info.CodeWords = kNumberOfUnwindCodeWords;

    // Generate unwind codes for the following prolog:
    //
    // stp fp, lr, [sp, #-kCallerSPOffset]!
    // mov fp, sp
    //
    // This is a very rough approximation of the actual function prologs used in
    // V8. In particular, we often push other data before the (fp, lr) pair,
    // meaning the stack pointer computed for the caller frame is wrong. That
    // error is acceptable when the unwinding info for the caller frame also
    // depends on fp rather than sp, as is the case for V8 builtins and runtime-
    // generated code.
    static_assert(kNumberOfUnwindCodeWords >= 1);
    uword kCallerSPOffset = -16;
    unwind_codes[0] = Combine8BitUnwindCodes(
        OpSetFp, MakeOpSaveFpLrX(kCallerSPOffset), OpEnd);

    // Fill the rest with nops.
    for (int i = 1; i < kNumberOfUnwindCodeWords; ++i) {
      unwind_codes[i] = Combine8BitUnwindCodes();
    }
  }
};

static const uint32_t kDefaultRuntimeFunctionCount = 1;
static constexpr uint32_t kUnwindingRecordMagic = 0xAABBCCEE;

struct TargetRuntimeFunction {
  ULONG BeginAddress;
  ULONG UnwindData;
};

struct CodeRangeUnwindingRecord {
  void* dynamic_table;
  uint32_t magic;
  uint32_t runtime_function_count;
  UnwindData<> unwind_info;
  uint32_t exception_handler;

  // For Windows ARM64 unwinding, register 2 unwind_info for each code range,
  // unwind_info for all full size ranges (1MB - 4 bytes) and unwind_info1 for
  // the remaining non full size range. There is at most 1 range which is less
  // than full size.
  UnwindData<> unwind_info1;

  // An arbitrary number of runtime function structs follow the initial header
  // as the number needed to cover the given code range is computed at runtime.
  // Must be cast to a PRUNTIME_FUNCTION when passed to Windows APIs.
  TargetRuntimeFunction runtime_function[kDefaultRuntimeFunctionCount];
};
#else
#error Unhandled Windows architecture.
#endif

// Since the definition of the RUNTIME_FUNCTION struct differs on X64
// and ARM64 Windows and the precompiler may be cross compiling between
// the two, TargetRuntimeFunction is defined above, which mimics the
// native RUNTIME_FUNCTION struct of the target.
//
// Make sure that the sizes match, so that TargetRuntimeFunction values
// can be used as RUNTIME_FUNCTION values and vice versa in the runtime.
#if defined(UNWINDING_RECORDS_WINDOWS_HOST)
static_assert(sizeof(TargetRuntimeFunction) == sizeof(RUNTIME_FUNCTION));
#endif

#pragma pack(pop)

#endif  // defined(NEED_WINDOWS_UNWINDING_RECORDS)

}  // namespace dart

#endif  // RUNTIME_PLATFORM_UNWINDING_RECORDS_H_
