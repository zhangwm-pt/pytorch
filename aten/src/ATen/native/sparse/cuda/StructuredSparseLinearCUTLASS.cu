#include <ATen/core/Tensor.h>
#include <ATen/cuda/CUDAUtils.h>
#include <ATen/Dispatch.h>

#ifndef USE_ROCM
#include <cutlass/cutlass.h>
#include <cutlass/gemm/device/gemm_sparse.h>
#endif

#include <type_traits>
#include <tuple>

#ifndef USE_ROCM
#define CUTLASS_STATUS_CHECK(status)                                      \
  {                                                                       \
    TORCH_CHECK(status == cutlass::Status::kSuccess,                      \
                "Got CUTLASS error: ", cutlassGetStatusString(status));   \
  }
#endif

namespace at {
namespace native {

#ifndef USE_ROCM
// This kernel is for creating 2:4 sparse matrix metadata for given
// "mask" matrix corresponding to the original dense matrix.  The
// "mask" matrix contains true values where dense matrix elements are
// zeros, and false values otherwise.  The "mask" matrix has
// "length_m" rows and "length_n" columns, and it is assumed that this
// matrix is in row-major format, with row stride "mask_stride" (and
// that the column stride is 1).  The kernel will store metadata in
// "meta" matrix, and it is also assumed that this matrix is in
// row-major format, with row stride "meta_stride" (and with the
// column stride equals 1).  If the "mask" matrix is not in 2:4 sparse
// format, the kernel will set value pointed by "error" to 1.
//
// This kernel could be improved for efficiency, but it should be
// called once for given sparse operand, so it should not affect
// performance much.
template<typename T>
__global__ void two_four_create_meta_kernel(
      const int length_m, const int length_k, const int mask_stride,
      const bool* mask, const int meta_stride, T* meta, int* error) {
    const auto k = blockDim.x * blockIdx.x + threadIdx.x;
    const auto m = blockDim.y * blockIdx.y + threadIdx.y;

    const auto in_range = m < length_m && k < length_k / 4;
    unsigned active_mask = __ballot_sync(0xffffffff, in_range);
    if (!in_range) {
        return;
    }

    T val = 0;
    const auto pos0 = mask[m * mask_stride + k * 4];
    const auto pos1 = mask[m * mask_stride + k * 4 + 1];
    const auto pos2 = mask[m * mask_stride + k * 4 + 2];
    const auto pos3 = mask[m * mask_stride + k * 4 + 3];
    const auto pos_tuple = std::make_tuple(pos0, pos1, pos2, pos3);

    // See
    // https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#warp-level-sparse-matrix-storage
    // There are only 6 valid configurations (4 choose 2) and for each
    // there is a special number.
    if (pos_tuple == std::make_tuple(1, 1, 0, 0)) {
        val = 4; // 0100
    } else if (pos_tuple == std::make_tuple(1, 0, 1, 0)) {
        val = 8; // 1000
    } else if (pos_tuple == std::make_tuple(0, 1, 1, 0)) {
        val = 9; // 1001
    } else if (pos_tuple == std::make_tuple(1, 0, 0, 1)) {
        val = 12; // 1100
    } else if (pos_tuple == std::make_tuple(0, 1, 0, 1)) {
        val = 13; // 1101
    } else if (pos_tuple == std::make_tuple(0, 0, 1, 1)) {
        val = 14; // 1110
    } else {
        atomicExch(error, 1);
    }

    auto tile_size = 2 * sizeof(T);
    for (auto i = 1; i < tile_size; i *= 2) {
        val |= __shfl_down_sync(active_mask, val, i) << (4 * i);
    }
    if (k % tile_size == 0) {
        meta[m * meta_stride + k / tile_size] = val;
    }
}

// This kernel reimplements reorder_meta() function from
// tools/util/include/cutlass/util/host_reorder.h file from CUTLASS
// source distribution.  The purpose of having CUDA version of this
// function is to avoid to copy meta matrix to CPU and back, as
// CUTLASS for now supplies only host versio of this function.
//
// Alike to the above kernel, this kernel should be called once for
// given sparse operand, so not much effort is put into the
// optimization (hopefully, CUTLASS may provide own CUDA version at
// some point).
template <typename Element, typename LayoutSrc, typename LayoutDest>
__global__ void two_four_reorder_meta_kernel(
      const int length_m, const int length_k,
      const cutlass::TensorRef<Element, LayoutSrc> src,
      cutlass::TensorRef<Element, LayoutDest> dst) {
    const int k = blockDim.x * blockIdx.x + threadIdx.x;
    const int m = blockDim.y * blockIdx.y + threadIdx.y;

    if (m >= length_m || k >= length_k) {
        return;
    }

    // First reorder the rows.
    int group = (sizeof(Element) == 2) ? 32 : 16;
    int interweave = (sizeof(Element) == 2) ? 4 : 2;

    int dst_row = m / group * group + (m % 8) * interweave + (m % group) / 8;
    int dst_col = k;

    // Next swizzle the 2x2 blocks from Z to N.
    if (((dst_row % 2) == 0) && ((dst_col % 2) == 1)) {
      ++dst_row;
      --dst_col;
    } else if (((dst_row % 2) == 1) && ((dst_col % 2) == 0)) {
      --dst_row;
      ++dst_col;
    }
    dst.at({dst_row, dst_col}) = src.at({m, k});
}

// Wrapper function for CUTLASS sparse GEMM implementation, used
// solely to simplify dispatching from _structured_sparse_linear()
// function below.
template <
    typename ElementInputA,
    typename ElementInputB,
    typename ElementOutput,
    typename ElementAccumulator,
    typename ElementComputeEpilogue,
    typename ThreadblockShape,
    typename WarpShape,
    typename InstructionShape,
    typename EpilogueOp,
    typename LayoutInputA,
    typename LayoutInputB>
std::tuple<Tensor, Tensor> two_four_sgemm_cutlass(
    const Tensor& tensor_a,
    const at::IntArrayRef::value_type& tensor_a_stride,
    const Tensor& tensor_b,
    const at::IntArrayRef::value_type& tensor_b_stride,
    const Tensor& mask_or_meta) {
    // Fix CUTLASS sparse GEMM template arguments that are not
    // provided as template argument of this function, and create an
    // alias for particular instantiation of this template.
    using LayoutOutput = cutlass::layout::RowMajor; // Result of the operation will be provided in row-major format.
    using MMAOp = cutlass::arch::OpClassTensorOp; // Tensor cores are to be used for maximum performance.
    using SmArch = cutlass::arch::Sm80; // Only CC 8.x devices are suported at the moment.
    using SwizzleThreadBlock = cutlass::gemm::threadblock::GemmIdentityThreadblockSwizzle<>; // This choice provides good performance across wide range of operand sizes.
    constexpr int NumStages = 3; // This choice provides good performance across wide range of operand sizes.
    using Gemm = cutlass::gemm::device::SparseGemm<
        ElementInputA,
        LayoutInputA,
        ElementInputB,
        LayoutInputB,
        ElementOutput,
        LayoutOutput,
        ElementAccumulator,
        MMAOp,
        SmArch,
        ThreadblockShape,
        WarpShape,
        InstructionShape,
        EpilogueOp,
        SwizzleThreadBlock,
        NumStages>;

    // Datatype and layout of metadata matrix are inferred from sparse
    // GEMM template.
    using ElementInputE = typename Gemm::ElementE;
    using LayoutInputE = cutlass::layout::RowMajor;
    using ReorderedLayoutInputE = typename Gemm::LayoutE;

    constexpr auto kSparse = Gemm::kSparse;
    constexpr int kElementsPerElementE = Gemm::kElementsPerElementE;

    // Operand sizes.
    const int length_m = tensor_a.size(0);
    const int length_k = tensor_b.size(0);
    const int length_n = tensor_b.size(1);
    const auto meta_ncols = length_k / kSparse / kElementsPerElementE;

    // Check for current CUTLASS limitations w.r.t. input sizes.
    constexpr auto input_a_is_half =
        std::is_same<ElementInputA, cutlass::half_t>::value;
    TORCH_CHECK(length_m % 32 == 0,
        "torch._structured_sparse_linear: Number of rows of sparse matrix must "
        "be divisible by 32");
    TORCH_CHECK(length_k % (input_a_is_half ? 64 : 128) == 0,
        "torch._structured_sparse_linear: Number of rows of dense matrix must "
        "be divisible by ", (input_a_is_half ? 64 : 128));
    TORCH_CHECK(length_n % (input_a_is_half ? 8 : 16) == 0,
        "torch._structured_sparse_linear: Number of columns of dense matrix "
        "must be divisible by ", (input_a_is_half ? 8 : 16));

    // Determine PyTorch datatype for the output matrix.
    auto tensor_d_dtype = at::kChar;
    if constexpr (std::is_same_v<ElementOutput, int32_t>) {
        tensor_d_dtype = at::kInt;
    }
    else if constexpr (std::is_same_v<ElementOutput, cutlass::half_t>) {
        tensor_d_dtype = at::kHalf;
    }
    else {
        AT_ERROR("torch._structured_sparse_linear: invalid sparse GEMM output "
                 "datatype encountered");
    }

    // Create output matrix.
    auto tensor_d =
        tensor_a.new_empty({length_m, length_n},
                           at::TensorOptions().dtype(tensor_d_dtype));

    // If mask matrix passed as an argument, create metadata matrix.
    // CUTLASS required metadata matrix in a shuffled order, so
    // perform the reordering in that case too.
    Tensor meta_reordered;
    if (mask_or_meta.dtype() == at::kBool) {
        auto mask = mask_or_meta;

        // Check dimensions and format of the mask matrix.
        TORCH_CHECK(mask.layout() == Layout::Strided,
            "torch._structured_sparse_linear: Expected mask argument to be "
            "strided, but got layout ", mask.layout());
        TORCH_CHECK(mask.dim() == 2,
            "torch._structured_sparse_linear: Expected mask argument to be 2D "
            "tensor, got ", mask.dim(), " dims");
        const auto strides_mask = mask.strides();
        TORCH_CHECK(strides_mask[1] == 1,
            "torch._structured_sparse_linear: Invalid strides for mask_or_meta "
            "argument: row stride = ", strides_mask[0], ", column stride = ",
                strides_mask[1]);

        // Determine PyTorch datatype for the metadata matrix.
        auto meta_dtype = at::kChar;
        switch (sizeof(ElementInputE)) {
        case 1:
            break;
        case 2:
            meta_dtype = at::kShort;
            break;
        case 4:
            meta_dtype = at::kInt;
            break;
        default:
            AT_ERROR("torch._structured_sparse_linear: invalid size of meta "
                     "tensor datatype encountered");
        }

        // Create tensor for metadata matrix, and run CUDA kernel to
        // build this matrix from mask matrix.
        auto meta = mask.new_empty({length_m, meta_ncols},
                                   at::TensorOptions().dtype(meta_dtype));
        auto error = mask.new_zeros({1}, at::TensorOptions().dtype(at::kInt));
        two_four_create_meta_kernel<<<
            dim3((length_k + 63) / 64, (length_m + 15) / 16),
            dim3(16, 16),
            0,
            at::cuda::getCurrentCUDAStream()>>> (
                length_m, length_k, strides_mask[0], (bool*)mask.data_ptr(),
                meta.stride(0), (ElementInputE*)meta.data_ptr(),
                (int*)error.data_ptr());
        C10_CUDA_KERNEL_LAUNCH_CHECK();
        TORCH_CHECK(error.item().equal(0),
                    "torch._structured_sparse_linear: Mask matrix is not 2:4 "
                    "sparse");

        // Create tensor for reordered metadata matrix, and run CUDA
        // kernel to build this matrix from above calculated metadata matrix.
        meta_reordered = meta.new_empty(meta.sizes());
        auto meta_device_ref =
            cutlass::TensorRef<ElementInputE, cutlass::layout::RowMajor>(
                (ElementInputE*)meta.data_ptr(),
                LayoutInputE::packed({length_m, meta_ncols}));
        auto meta_reordered_device_ref =
            cutlass::TensorRef<ElementInputE, ReorderedLayoutInputE>(
                (ElementInputE*)meta_reordered.data_ptr(),
                ReorderedLayoutInputE::packed({length_m, meta_ncols}));
        two_four_reorder_meta_kernel<<<
            dim3((meta_ncols + 15) / 16, (length_m + 15) / 16),
            dim3(16, 16),
            0,
            at::cuda::getCurrentCUDAStream()>>> (
                length_m, meta_ncols, meta_device_ref,
                meta_reordered_device_ref);
        C10_CUDA_KERNEL_LAUNCH_CHECK();
    }
    else {
        meta_reordered = mask_or_meta;
    }

    // Prepare arguments for CUTLASS sparse GEMM kernel.
    cutlass::gemm::GemmCoord problem_size(length_m, length_n, length_k);
    LayoutInputA layout_a(tensor_a_stride);
    LayoutInputB layout_b(tensor_b_stride);
    LayoutOutput layout_d(tensor_d.stride(0));
    auto tensor_a_device_ref =
        cutlass::TensorRef<ElementInputA, LayoutInputA>(
            (ElementInputA*)tensor_a.data_ptr(), layout_a);
    auto tensor_b_device_ref =
        cutlass::TensorRef<ElementInputB, LayoutInputB>(
            (ElementInputB*)tensor_b.data_ptr(), layout_b);
    auto tensor_d_device_ref =
        cutlass::TensorRef<ElementOutput, LayoutOutput>(
            (ElementOutput*)tensor_d.data_ptr(), layout_d);
    auto tensor_e_reordered_device_ref =
        cutlass::TensorRef<ElementInputE, ReorderedLayoutInputE>(
            (ElementInputE*)meta_reordered.data_ptr(),
            ReorderedLayoutInputE::packed({length_m, meta_ncols}));
    ElementComputeEpilogue alpha(1);
    ElementComputeEpilogue beta(0);
    constexpr int split_k_slices = 1;

    // Create a tuple of CUTLASS sparse GEMM kernel arguments.
    typename Gemm::Arguments arguments{
        problem_size,
        tensor_a_device_ref,
        tensor_b_device_ref,
        tensor_d_device_ref,
        tensor_d_device_ref,
        tensor_e_reordered_device_ref,
        {alpha, beta},
        split_k_slices};

    cutlass::Status status;

    // Create CUTLASS sparse GEMM kernel object.
    Gemm gemm_op;

    // Verify that sparse GEMM operation with given arguments can be
    // performed by CUTLASS.
    status = gemm_op.can_implement(arguments);
    CUTLASS_STATUS_CHECK(status);

    // Allocate workspace for CUTLASS sparse GEMM kernel.
    const auto workspace_size = Gemm::get_workspace_size(arguments);
    auto workspace = tensor_a.new_empty({(int64_t)workspace_size},
                                        at::TensorOptions().dtype(at::kByte));

    // Initialize CUTLASS sparse GEMM object.
    status = gemm_op.initialize(arguments, workspace.data_ptr(),
                                at::cuda::getCurrentCUDAStream());
    CUTLASS_STATUS_CHECK(status);

    // Perform sparse GEMM operation.
    status = gemm_op.run(at::cuda::getCurrentCUDAStream());
    CUTLASS_STATUS_CHECK(status);

    C10_CUDA_KERNEL_LAUNCH_CHECK();

    return std::make_tuple(tensor_d, meta_reordered);
}
#endif

// Perform GEMM operation between matrix with 2:4 sparsity pattern,
// and dense matrix, using corresponding CUTLASS sparse GEMM kernel.
// The sparse matrix is given as argument "tensor_a" and the dense
// matrix is given as argument "tensor_b".  It is assummed that
// matrices are supplied either in row-major or column-major format
// (matrices could be in different formats, but not all combinations
// of formats are supported for some datatypes of these matrices).
// The "mask_or_meta" argument contains either a mask matrix
// corresponding to the original dense matrix with 2:4 sparsity
// pattern, from which sparse matrix "tensor_a" is compressed, or to
// the corresponding metadata matrix.  The function differentiates
// between these two cases by the datatype of "mask_or_meta" tensor:
// if it is of boolean datatype, then it is assumed that the mask
// matrix is passed, otherwise it is assumed that the metadata matrix
// is passed.  In the first case, metadata matrix is calculated from
// the matrix matrix.  The function returns a tupple with the product
// of "tensor_a" and "tensor_b" matrices, and metadata matrix (either
// calculated by this function, in case mask is passed as
// "mask_or_meta" argument, or the same one that is passed to this
// function otherwise).
//
// There exists numerous limitations of CUTLASS sparse GEMM kernel,
// with regards to sizes and alignments of input tensors, their
// layouts and datatypes, and so on; this is the reason for large
// number of checks throughout the code.
std::tuple<Tensor, Tensor> _structured_sparse_linear(
      const Tensor& tensor_a, const Tensor& tensor_b,
      const Tensor& mask_or_meta) {
#ifndef USE_ROCM
    // No need to check that all tensors are on CUDA device, as this
    // is provided by dispatch.

    // For now, only CC 8.x devices are supported.
    const auto dprops = at::cuda::getCurrentDeviceProperties();
    const auto is_sm8x = dprops->major == 8;
    TORCH_CHECK(is_sm8x,
                "torch._structured_sparse_linear: Supported only on GPUs with "
                "compute capability 8.x");

    // Validate layouts of input tensors.
    TORCH_CHECK(tensor_a.layout() == Layout::Strided,
                "torch._structured_sparse_linear: Expected tensor_a argument "
                "to be strided, but got layout ", tensor_a.layout());
    TORCH_CHECK(tensor_a.dim() == 2,
                "torch._structured_sparse_linear: Expected tensor_a argument "
                "to be 2D tensor, got ", tensor_a.dim(), " dims");
    const auto strides_a = tensor_a.strides();
    TORCH_CHECK((strides_a[0] == 1 || strides_a[1] == 1) && strides_a[0] != strides_a[1],
                "torch._structured_sparse_linear: Invalid strides for tensor_a "
                "argument: row stride = ", strides_a[0], ", column stride = ",
                strides_a[1]);
    TORCH_CHECK(tensor_b.layout() == Layout::Strided,
                "torch._structured_sparse_linear: Expected tensor_b argument "
                "to be strided, but got layout ", tensor_b.layout());
    TORCH_CHECK(tensor_b.dim() == 2,
                "torch._structured_sparse_linear: Expected tensor_b argument "
                "to be 2D tensor, got ", tensor_b.dim(), " dims");
    const auto strides_b = tensor_b.strides();
    TORCH_CHECK((strides_b[0] == 1 || strides_b[1] == 1) && strides_b[0] != strides_b[1],
                "torch._structured_sparse_linear: Invalid strides for tensor_b "
                "argument: row stride = ", strides_b[0], ", column stride = ",
                strides_b[1]);

    // Determine layout (row-major or column-major) of input tensors.
    auto tensor_a_row_major = strides_a[1] == 1;
    auto tensor_a_stride = tensor_a_row_major ? strides_a[0] : strides_a[1];
    auto tensor_b_row_major = strides_b[1] == 1;
    auto tensor_b_stride = tensor_b_row_major ? strides_b[0] : strides_b[1];

    // Call wrapper function for CUTLASS sparse GEMM, dispatching on
    // the input datatype, and then on input tensors layouts.
    // According to the input tensors datatypes and layouts,
    // correspnding template arguments are supplied for instantiating
    // the wrapper function.  The tile sizes template arguments are
    // selected according to the CUTLASS profiler results, for number
    // of runs.
    std::tuple<Tensor, Tensor> result;
    AT_DISPATCH_SWITCH(
        tensor_a.scalar_type(),
        "_structured_sparse_linear",
        AT_DISPATCH_CASE(
            at::ScalarType::Char,
            [&]() {
                using ElementInputA = int8_t;
                using ElementInputB = int8_t;
                using ElementOutput = int32_t;
                using ElementAccumulator = int32_t;
                using ElementComputeEpilogue = int32_t;
                using ThreadblockShape = cutlass::gemm::GemmShape<128, 128, 128>;
                using WarpShape = cutlass::gemm::GemmShape<64, 64, 128>;
                using InstructionShape = cutlass::gemm::GemmShape<16, 8, 64>;
                using EpilogueOp = cutlass::epilogue::thread::LinearCombination<
                    ElementOutput,
                    128 / cutlass::sizeof_bits<ElementOutput>::value,
                    ElementAccumulator,
                    ElementComputeEpilogue>;
                if (tensor_a_row_major && !tensor_b_row_major) {
                    result = two_four_sgemm_cutlass<
                        ElementInputA,
                        ElementInputB,
                        ElementOutput,
                        ElementAccumulator,
                        ElementComputeEpilogue,
                        ThreadblockShape,
                        WarpShape,
                        InstructionShape,
                        EpilogueOp,
                        cutlass::layout::RowMajor,
                        cutlass::layout::ColumnMajor>(
                        tensor_a,
                        tensor_a_stride,
                        tensor_b,
                        tensor_b_stride,
                        mask_or_meta);
                    return;
                }
                AT_ERROR("torch._structured_sparse_linear: Combination of "
                         "tensor_a in ",
                         tensor_a_row_major ? "row-major" : "column_major",
                         " layout and tensor_b in ",
                         tensor_b_row_major ? "row-major" : "column_major",
                         " layout is not supported");
            })
        AT_DISPATCH_CASE(
            at::ScalarType::Half,
            [&]() {
                using ElementInputA = cutlass::half_t;
                using ElementInputB = cutlass::half_t;
                using ElementOutput = cutlass::half_t;
                using ElementAccumulator = float;
                using ElementComputeEpilogue = cutlass::half_t;
                using ThreadblockShape = cutlass::gemm::GemmShape<128, 128, 64>;
                using WarpShape = cutlass::gemm::GemmShape<64, 64, 64>;
                using InstructionShape = cutlass::gemm::GemmShape<16, 8, 32>;
                using EpilogueOp = cutlass::epilogue::thread::LinearCombination<
                    ElementOutput,
                    128 / cutlass::sizeof_bits<ElementOutput>::value,
                    ElementAccumulator,
                    ElementComputeEpilogue>;
                if (tensor_a_row_major && tensor_b_row_major) {
                    result = two_four_sgemm_cutlass<
                        ElementInputA,
                        ElementInputB,
                        ElementOutput,
                        ElementAccumulator,
                        ElementComputeEpilogue,
                        ThreadblockShape,
                        WarpShape,
                        InstructionShape,
                        EpilogueOp,
                        cutlass::layout::RowMajor,
                        cutlass::layout::RowMajor>(
                        tensor_a,
                        tensor_a_stride,
                        tensor_b,
                        tensor_b_stride,
                        mask_or_meta);
                    return;
                }
                if (tensor_a_row_major && !tensor_b_row_major) {
                    result = two_four_sgemm_cutlass<
                        ElementInputA,
                        ElementInputB,
                        ElementOutput,
                        ElementAccumulator,
                        ElementComputeEpilogue,
                        ThreadblockShape,
                        WarpShape,
                        InstructionShape,
                        EpilogueOp,
                        cutlass::layout::RowMajor,
                        cutlass::layout::ColumnMajor>(
                        tensor_a,
                        tensor_a_stride,
                        tensor_b,
                        tensor_b_stride,
                        mask_or_meta);
                    return;
                }
                if (!tensor_a_row_major && tensor_b_row_major) {
                    result = two_four_sgemm_cutlass<
                        ElementInputA,
                        ElementInputB,
                        ElementOutput,
                        ElementAccumulator,
                        ElementComputeEpilogue,
                        ThreadblockShape,
                        WarpShape,
                        InstructionShape,
                        EpilogueOp,
                        cutlass::layout::ColumnMajor,
                        cutlass::layout::RowMajor>(
                        tensor_a,
                        tensor_a_stride,
                        tensor_b,
                        tensor_b_stride,
                        mask_or_meta);
                    return;
                }
                if (!tensor_a_row_major && !tensor_b_row_major) {
                    result = two_four_sgemm_cutlass<
                        ElementInputA,
                        ElementInputB,
                        ElementOutput,
                        ElementAccumulator,
                        ElementComputeEpilogue,
                        ThreadblockShape,
                        WarpShape,
                        InstructionShape,
                        EpilogueOp,
                        cutlass::layout::ColumnMajor,
                        cutlass::layout::ColumnMajor>(
                        tensor_a,
                        tensor_a_stride,
                        tensor_b,
                        tensor_b_stride,
                        mask_or_meta);
                    return;
                }
            }));
    return result;
#else
    AT_ERROR("torch._structured_sparse_linear: ROCm doesn't support CUTLASS");
    return std::make_tuple(Tensor{}, Tensor{});
#endif
}

} // namespace native
} // namespace at
