cimport numpy as np
import numpy as np
from libc.math cimport sqrt, exp, pi, floor, ceil, fabs
from cython.parallel import prange, parallel
from libc.stdlib cimport malloc, free
from libc.string cimport memset
cimport openmp
from . cimport pyfftw
from . import pyfftw
from . cimport simulation as sim

# Numpy must be initialized. When using numpy from C or Cython you must
# *ALWAYS* do that, or you will have segfaults
np.import_array()

ctypedef fused float_t:
    np.float64_t
    np.float32_t

ctypedef fused uint_t:
    np.uint64_t
    np.uint32_t

DEF FLOAT_MAX = 1.7976931348623157e+308
DEF M_1_SQRT2PI = 0.3989422804014327

ctypedef double (*loss_func)(double a) nogil

cdef double Huber_loss(double a) nogil:
    cdef double aa = fabs(a)
    if aa < 1.345:
        return 0.5 * a * a
    elif 1.345 <= aa < 3.0:
        return 1.345 * (aa - 0.6725)
    else:
        return 3.1304875

cdef double Epsilon_loss(double a) nogil:
    cdef double aa = fabs(a)
    if aa < 0.25:
        return 0.0
    elif 0.25 <= aa < 3.0:
        return aa - 0.25
    else:
        return 2.75

cdef double l2_loss(double a) nogil:
    if -3.0 < a < 3.0:
        return a * a
    else:
        return 9.0

cdef double l1_loss(double a) nogil:
    if -3.0 < a < 3.0:
        return fabs(a)
    else:
        return 3.0

cdef loss_func choose_loss(str loss):
    cdef loss_func f
    if loss == 'Epsilon':
        f = Epsilon_loss
    elif loss == 'Huber':
        f = Huber_loss
    elif loss == 'L2':
        f = l2_loss
    elif loss == 'L1':
        f = l1_loss
    else:
        raise ValueError('loss keyword is invalid')
    return f

cdef float_t min_float(float_t* array, int a) nogil:
    cdef:
        int i
        float_t mv = array[0]
    for i in range(a):
        if array[i] < mv:
            mv = array[i]
    return mv

cdef float_t max_float(float_t* array, int a) nogil:
    cdef:
        int i
        float_t mv = array[0]
    for i in range(a):
        if array[i] > mv:
            mv = array[i]
    return mv

cdef double rbf(double dsq, double h) nogil:
    return exp(-0.5 * dsq / (h * h)) * M_1_SQRT2PI

cdef void KR_frame_1d(float_t[:, ::1] I0, float_t[:, ::1] w0, uint_t[:, ::1] I_n,
                      float_t[:, ::1] W, float_t[:, :, ::1] u, float_t dj,
                      double ds_x, double h) nogil:
    cdef int X = I_n.shape[1], X0 = I0.shape[1], k, kk, k0, kk0, kk1
    cdef int dn = <int>ceil((4.0 * h) / ds_x)
    cdef double x, r

    for k in range(X):
        x = u[1, 0, k] - dj
        k0 = <int>(x / ds_x) + 1

        kk0 = k0 - dn if k0 - dn > 0 else 0
        kk1 = k0 + dn if k0 + dn < X0 else X0

        for kk in range(kk0, kk1):
            r = rbf((ds_x * kk - x) * (ds_x * kk - x), h)
            I0[0, kk] += I_n[0, k] * W[0, k] * r
            w0[0, kk] += W[0, k] * W[0, k] * r

cdef void KR_frame_2d(float_t[:, ::1] I0, float_t[:, ::1] w0, uint_t[:, ::1] I_n,
                      float_t[:, ::1] W, float_t[:, :, ::1] u, float_t di, float_t dj,
                      double ds_y, double ds_x, double h) nogil:
    cdef int Y = I_n.shape[0], X = I_n.shape[1], Y0 = I0.shape[0], X0 = I0.shape[1]
    cdef int j, k, jj, kk, j0, k0, jj0, jj1, kk0, kk1
    cdef int dn_y = <int>ceil((4.0 * h) / ds_y), dn_x = <int>ceil((4.0 * h) / ds_x)
    cdef double y, x, r

    for j in range(Y):
        for k in range(X):
            y = u[0, j, k] - di
            x = u[1, j, k] - dj
            j0 = <int>(y / ds_y) + 1
            k0 = <int>(x / ds_x) + 1

            jj0 = j0 - dn_y if j0 - dn_y > 0 else 0
            jj1 = j0 + dn_y if j0 + dn_y < Y0 else Y0
            kk0 = k0 - dn_x if k0 - dn_x > 0 else 0
            kk1 = k0 + dn_x if k0 + dn_x < X0 else X0

            for jj in range(jj0, jj1):
                for kk in range(kk0, kk1):
                    r = rbf((ds_y * jj - y) * (ds_y * jj - y) + (ds_x * kk - x) * (ds_x * kk - x), h)
                    I0[jj, kk] += I_n[j, k] * W[j, k] * r
                    w0[jj, kk] += W[j, k] * W[j, k] * r

def KR_reference(uint_t[:, :, ::1] I_n not None, float_t[:, ::1] W not None, float_t[:, :, ::1] u not None,
                 float_t[::1] di not None, float_t[::1] dj not None, double ds_y, double ds_x, double h,
                 bint return_nm0=True, unsigned num_threads=1):
    r"""Generate an unabberated reference image of the sample
    based on the pixel mapping `u` and the measured data `I_n`
    using the Kernel regression.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    u : numpy.ndarray
        The pixel mapping between the data at
        the detector plane and the reference image at
        the reference plane.
    di : numpy.ndarray
        Sample's translations along the vertical detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    ds_y : float
        Sampling interval in pixels along the vertical axis.
    ds_x : float
        Sampling interval in pixels along the horizontal axis.
    h : float
        Gaussian kernel bandwidth in pixels.
    return_nm0 : bool
        If True, also returns the lower bounds (`n0`, `m0`)
        of the reference image in pixels.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    I0 : numpy.ndarray
        Reference image array.
    n0 : int, optional
        The lower bounds of the vertical detector axis of
        the reference image at the reference frame in pixels.
        Only provided if `return_nm0` is True.
    m0 : int, optional
        The lower bounds of the fast detector axis of
        the reference image at the reference frame in pixels.
        Only provided if `return_nm0` is True.

    Notes
    -----
    Reference image update algorithm the detector plane to the
    reference plane using the pixel mapping `u`:

    .. math::
        ii_{0}, jj_{0} = u[0, i, j] - di[n], u[1, i, j] - dj[n]

    Whereupon it generates a smoothed sample profile using
    kernel regression approach with the gaussian kernel :math:`\phi`:

    .. math::

        I_{ref}[ii, jj] = \frac{\sum_{n, i, j} I_n[i, j] W[i, j]
        \phi[ii - u[0, i, j] + di[n], jj - u[1, i, j] + dj[n]]}
        {\sum_{n, i, j} W[i, j]^2 \phi[ii - u[0, i, j] + di[n],
        jj - u[1, i, j] + dj[n]]}

    .. math::

        \phi [\Delta ii_{ref}, \Delta jj_{ref}] = 
        \exp\left[{-\frac{(\Delta ii_{ref})^2 + 
        (\Delta jj_{ref})^2}{ls^2}}\right]
    """
    if ds_y <= 0.0 or ds_x <= 0.0:
        raise ValueError('Sampling intervals must be positive')

    cdef int type_num = np.PyArray_TYPE(W.base)
    cdef int N = I_n.shape[0], Y = I_n.shape[1], X = I_n.shape[2]
    cdef int i, j, t, k

    cdef float_t n0 = -min_float(&u[0, 0, 0], Y * X) + max_float(&di[0], N)
    cdef float_t m0 = -min_float(&u[1, 0, 0], Y * X) + max_float(&dj[0], N)
    cdef int Y0 = <int>((max_float(&u[0, 0, 0], Y * X) - min_float(&di[0], N) + n0) / ds_y) + 1
    cdef int X0 = <int>((max_float(&u[1, 0, 0], Y * X) - min_float(&dj[0], N) + m0) / ds_x) + 1
        
    cdef np.npy_intp *shape = [num_threads, Y0, X0]
    cdef float_t[:, :, ::1] I0_buf = np.PyArray_ZEROS(3, shape, type_num, 0)
    cdef float_t[:, :, ::1] W0_buf = np.PyArray_ZEROS(3, shape, type_num, 0)
    cdef np.ndarray I0 = np.PyArray_SimpleNew(2, shape + 1, type_num)

    if Y0 > 1:
        for i in prange(N, schedule='guided', num_threads=num_threads, nogil=True):
            t = openmp.omp_get_thread_num()
            KR_frame_2d(I0_buf[t], W0_buf[t], I_n[i], W, u, di[i] - n0, dj[i] - m0, ds_y, ds_x, h)
    else:
        for i in prange(N, schedule='guided', num_threads=num_threads, nogil=True):
            t = openmp.omp_get_thread_num()
            KR_frame_1d(I0_buf[t], W0_buf[t], I_n[i], W, u, dj[i] - m0, ds_x, h)

    cdef float_t[:, ::1] _I0 = I0
    cdef float_t I0_sum, W0_sum
    for k in prange(X0, schedule='guided', num_threads=num_threads, nogil=True):
        for j in range(Y0):
            I0_sum = 0.0; W0_sum = 0.0
            for i in range(<int>num_threads):
                I0_sum = I0_sum + I0_buf[i, j, k]
                W0_sum = W0_sum + W0_buf[i, j, k]

            _I0[j, k] = I0_sum / W0_sum if W0_sum > 0.0 else 1.0

    if return_nm0:
        return I0, <int>n0, <int>m0
    else:
        return I0

cdef void LOWESS_frame_1d(float_t[:, ::1] W_sum, float_t[:, :, ::1] M_mat, float_t[:, :, ::1] I0_mat,
                          float_t[:, :, ::1] W0_mat, uint_t[:, ::1] I_n, float_t[:, ::1] W,
                          float_t[:, :, ::1] u, float_t dj, double ds_x, double h) nogil:
    cdef int X = I_n.shape[1], X0 = W_sum.shape[1]
    cdef int k, kk, j0, k0, kk0, kk1
    cdef int dn = <int>ceil((4.0 * h) / ds_x)
    cdef double x, r, w

    for k in range(X):
        x = u[1, 0, k] - dj
        k0 = <int>(x / ds_x) + 1

        kk0 = k0 - dn if k0 - dn > 0 else 0
        kk1 = k0 + dn if k0 + dn < X0 else X0
    
        for kk in range(kk0, kk1):
            r = rbf((ds_x * kk - x) * (ds_x * kk - x), h)
            W_sum[0, kk] += r
            w = r / W_sum[0, kk]

            M_mat[0, kk, 1] += w * (x - M_mat[0, kk, 1])
            M_mat[0, kk, 3] += w * (x * x - M_mat[0, kk, 3])

            I0_mat[0, kk, 0] += w * (I_n[0, k] * W[0, k] - I0_mat[0, kk, 0])
            I0_mat[0, kk, 2] += w * (I_n[0, k] * W[0, k] * x - I0_mat[0, kk, 2])

            W0_mat[0, kk, 0] += w * (W[0, k] * W[0, k] - W0_mat[0, kk, 0])
            W0_mat[0, kk, 2] += w * (W[0, k] * W[0, k] * x - W0_mat[0, kk, 2])

cdef void LOWESS_frame_2d(float_t[:, ::1] W_sum, float_t[:, :, ::1] M_mat, float_t[:, :, ::1] I0_mat,
                          float_t[:, :, ::1] W0_mat, uint_t[:, ::1] I_n, float_t[:, ::1] W,
                          float_t[:, :, ::1] u, float_t di, float_t dj, double ds_y, double ds_x, double h) nogil:
    cdef int Y = I_n.shape[0], X = I_n.shape[1], Y0 = W_sum.shape[0], X0 = W_sum.shape[1]
    cdef int j, k, jj, kk, j0, k0, jj0, jj1, kk0, kk1
    cdef int dn_y = <int>ceil((4.0 * h) / ds_y), dn_x = <int>ceil((4.0 * h) / ds_x)
    cdef double y, x, r, w

    for j in range(Y):
        for k in range(X):
            y = u[0, j, k] - di
            x = u[1, j, k] - dj
            j0 = <int>(y / ds_y) + 1
            k0 = <int>(x / ds_x) + 1

            jj0 = j0 - dn_y if j0 - dn_y > 0 else 0
            jj1 = j0 + dn_y if j0 + dn_y < Y0 else Y0
            kk0 = k0 - dn_x if k0 - dn_x > 0 else 0
            kk1 = k0 + dn_x if k0 + dn_x < X0 else X0
        
            for jj in range(jj0, jj1):
                for kk in range(kk0, kk1):
                    r = rbf((ds_y * jj - y) * (ds_y * jj - y) + (ds_x * kk - x) * (ds_x * kk - x), h)
                    W_sum[jj, kk] += r
                    w = r / W_sum[jj, kk]

                    M_mat[jj, kk, 0] += w * (y - M_mat[jj, kk, 0])
                    M_mat[jj, kk, 1] += w * (x - M_mat[jj, kk, 1])
                    M_mat[jj, kk, 2] += w * (y * y - M_mat[jj, kk, 2])
                    M_mat[jj, kk, 3] += w * (x * x - M_mat[jj, kk, 3])

                    I0_mat[jj, kk, 0] += w * (I_n[j, k] * W[j, k] - I0_mat[jj, kk, 0])
                    I0_mat[jj, kk, 1] += w * (I_n[j, k] * W[j, k] * y - I0_mat[jj, kk, 1])
                    I0_mat[jj, kk, 2] += w * (I_n[j, k] * W[j, k] * x - I0_mat[jj, kk, 2])

                    W0_mat[jj, kk, 0] += w * (W[j, k] * W[j, k] - W0_mat[jj, kk, 0])
                    W0_mat[jj, kk, 1] += w * (W[j, k] * W[j, k] * y - W0_mat[jj, kk, 1])
                    W0_mat[jj, kk, 2] += w * (W[j, k] * W[j, k] * x - W0_mat[jj, kk, 2])

def LOWESS_reference(uint_t[:, :, ::1] I_n not None, float_t[:, ::1] W not None, float_t[:, :, ::1] u not None,
                     float_t[::1] di not None, float_t[::1] dj not None, double ds_y, double ds_x, double h,
                     bint return_nm0=True, unsigned num_threads=1):
    r"""Generate an unabberated reference image of the sample
    based on the pixel mapping `u` and the measured data `I_n`
    using the Local Weighted Linear Regression (LOWESS).

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    u : numpy.ndarray
        The pixel mapping between the data at
        the detector plane and the reference image at
        the reference plane.
    di : numpy.ndarray
        Sample's translations along the vertical detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    ds_y : float
        Sampling interval in pixels along the vertical axis.
    ds_x : float
        Sampling interval in pixels along the horizontal axis.
    h : float
        Gaussian kernel bandwidth in pixels.
    return_nm0 : bool
        If True, also returns the lower bounds (`n0`, `m0`)
        of the reference image in pixels.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    I0 : numpy.ndarray
        Reference image array.
    n0 : int, optional
        The lower bounds of the vertical detector axis of
        the reference image at the reference frame in pixels.
        Only provided if `return_nm0` is True.
    m0 : int, optional
        The lower bounds of the fast detector axis of
        the reference image at the reference frame in pixels.
        Only provided if `return_nm0` is True.
    """
    if ds_y <= 0.0 or ds_x <= 0.0:
        raise ValueError('Sampling intervals must be positive')

    cdef int type_num = np.PyArray_TYPE(W.base)
    cdef int N = I_n.shape[0], Y = I_n.shape[1], X = I_n.shape[2]
    cdef int i, j, t, k

    cdef float_t n0 = -min_float(&u[0, 0, 0], Y * X) + max_float(&di[0], N)
    cdef float_t m0 = -min_float(&u[1, 0, 0], Y * X) + max_float(&dj[0], N)
    cdef int Y0 = <int>((max_float(&u[0, 0, 0], Y * X) - min_float(&di[0], N) + n0) / ds_y) + 1
    cdef int X0 = <int>((max_float(&u[1, 0, 0], Y * X) - min_float(&dj[0], N) + m0) / ds_x) + 1
        
    cdef np.npy_intp *shape = [num_threads, Y0, X0, 4]
    cdef float_t[:, :, ::1] W_buf = np.PyArray_ZEROS(3, shape, type_num, 0)
    cdef float_t[:, :, :, ::1] M_buf = np.PyArray_ZEROS(4, shape, type_num, 0)
    shape[3] = 3
    cdef float_t[:, :, :, ::1] I0_buf = np.PyArray_ZEROS(4, shape, type_num, 0)
    cdef float_t[:, :, :, ::1] W0_buf = np.PyArray_ZEROS(4, shape, type_num, 0)
    cdef np.ndarray I0 = np.PyArray_SimpleNew(2, shape + 1, type_num)

    if Y0 > 1:
        for i in prange(N, schedule='guided', num_threads=num_threads, nogil=True):
            t = openmp.omp_get_thread_num()
            LOWESS_frame_2d(W_buf[t], M_buf[t], I0_buf[t], W0_buf[t], I_n[i], W, u,
                            di[i] - n0, dj[i] - m0, ds_y, ds_x, h)
    else:
        for i in prange(N, schedule='guided', num_threads=num_threads, nogil=True):
            t = openmp.omp_get_thread_num()
            LOWESS_frame_1d(W_buf[t], M_buf[t], I0_buf[t], W0_buf[t], I_n[i], W, u,
                            dj[i] - m0, ds_x, h)

    cdef float_t[:, ::1] _I0 = I0
    cdef float_t W_sum, w, betta_y, betta_x, var_y, var_x, I0_pred, W0_pred
    cdef float_t *M_mat
    cdef float_t *I0_mat
    cdef float_t *W0_mat

    with nogil, parallel(num_threads=num_threads):
        M_mat = <float_t *>malloc(4 * sizeof(float_t))
        I0_mat = <float_t *>malloc(3 * sizeof(float_t))
        W0_mat = <float_t *>malloc(3 * sizeof(float_t))

        for k in prange(X0, schedule='guided'):

            for j in range(Y0):
                W_sum = 0.0
                memset(M_mat, 0, 4 * sizeof(float_t))
                memset(I0_mat, 0, 3 * sizeof(float_t))
                memset(W0_mat, 0, 3 * sizeof(float_t))

                for i in range(<int>num_threads):
                    if W_buf[i, j, k] > 0.0:
                        W_sum = W_sum + W_buf[i, j, k]
                        w = W_buf[i, j, k] / W_sum

                        for t in range(4):
                            M_mat[t] = M_mat[t] + w * (M_buf[i, j, k, t] - M_mat[t])
                        
                        for t in range(3):
                            I0_mat[t] = I0_mat[t] + w * (I0_buf[i, j, k, t] - I0_mat[t])
                            W0_mat[t] = W0_mat[t] + w * (W0_buf[i, j, k, t] - W0_mat[t])

                var_y = M_mat[2] - M_mat[0] * M_mat[0]
                var_x = M_mat[3] - M_mat[1] * M_mat[1]

                betta_y = (I0_mat[1] - I0_mat[0] * M_mat[0]) / var_y if var_y > 0.0 else 0.0
                betta_x = (I0_mat[2] - I0_mat[0] * M_mat[1]) / var_x if var_x > 0.0 else 0.0

                I0_pred = I0_mat[0] - betta_y * (ds_y * j - M_mat[0]) - betta_x * (ds_x * k - M_mat[1])

                betta_y = (W0_mat[1] - W0_mat[0] * M_mat[0]) / var_y if var_y > 0.0 else 0.0
                betta_x = (W0_mat[2] - W0_mat[0] * M_mat[1]) / var_x if var_x > 0.0 else 0.0

                W0_pred = W0_mat[0] - betta_y * (ds_y * j - M_mat[0]) - betta_x * (ds_x * k - M_mat[1])

                _I0[j, k] = I0_pred / W0_pred if W0_pred > 0.0 else 1.0

        free(M_mat); free(I0_mat); free(W0_mat)

    if return_nm0:
        return I0, <int>n0, <int>m0
    else:
        return I0

cdef double FVU_interp(uint_t[:, :, ::1] I_n, float_t W, float_t[:, ::1] I0, float_t[::1] di, float_t[::1] dj, int j, int k,
                       float_t ux, float_t uy, double ds_y, double ds_x, double sigma, loss_func f) nogil:
    """Return fraction of variance unexplained between the validation set I and trained
    profile I0. Find the predicted values at the points (y, x) with bilinear interpolation.
    """
    cdef int N = I_n.shape[0], Y0 = I0.shape[0], X0 = I0.shape[1]
    cdef int i, y0, y1, x0, x1
    cdef double y, x, dy, dx, I0_bi, err = 0.0

    for i in range(N):
        y = (ux - di[i]) / ds_y
        x = (uy - dj[i]) / ds_x

        if y <= 0.0:
            dy = 0.0; y0 = 0; y1 = 0
        elif y >= Y0 - 1.0:
            dy = 0.0; y0 = Y0 - 1; y1 = Y0 - 1
        else:
            dy = y - floor(y)
            y0 = <int>floor(y); y1 = y0 + 1

        if x <= 0.0:
            dx = 0.0; x0 = 0; x1 = 0
        elif x >= X0 - 1.0:
            dx = 0.0; x0 = X0 - 1; x1 = X0 - 1
        else:
            dx = x - floor(x)
            x0 = <int>floor(x); x1 = x0 + 1

        I0_bi = (1.0 - dy) * (1.0 - dx) * I0[y0, x0] + \
                (1.0 - dy) * dx * I0[y0, x1] + \
                dy * (1.0 - dx) * I0[y1, x0] + \
                dy * dx * I0[y1, x1]
        err += f((<double>I_n[i, j, k] - W * I0_bi) / sigma)
    
    return err / N

cdef double FVU_interp_tr(float_t[:, ::1] errors, uint_t[:, ::1] I_n, float_t[:, ::1] W,
                          float_t[:, ::1] I0, float_t[:, :, ::1] u, float_t di0, float_t dj0, float_t di,
                          float_t dj, double ds_y, double ds_x, double sigma, loss_func f) nogil:
    """Return fraction of variance unexplained between the validation set I and trained
    profile I0. Find the predicted values at the points (y, x) with bilinear interpolation.
    """
    cdef int Y = I_n.shape[0], X = I_n.shape[1], Y0 = I0.shape[0], X0 = I0.shape[1]
    cdef int j, k, y0, y1, x0, x1
    cdef double y, x, dy, dx, I0_bi, err0, err1, err = 0.0

    for j in range(Y):
        for k in range(X):
            y = (u[0, j, k] - di0) / ds_y
            x = (u[1, j, k] - dj0) / ds_x

            if y <= 0.0:
                dy = 0.0; y0 = 0; y1 = 0
            elif y >= Y0 - 1.0:
                dy = 0.0; y0 = Y0 - 1; y1 = Y0 - 1
            else:
                dy = y - floor(y)
                y0 = <int>floor(y); y1 = y0 + 1

            if x <= 0.0:
                dx = 0.0; x0 = 0; x1 = 0
            elif x >= X0 - 1.0:
                dx = 0.0; x0 = X0 - 1; x1 = X0 - 1
            else:
                dx = x - floor(x)
                x0 = <int>floor(x); x1 = x0 + 1

            I0_bi = (1.0 - dy) * (1.0 - dx) * I0[y0, x0] + \
                    (1.0 - dy) * dx * I0[y0, x1] + \
                    dy * (1.0 - dx) * I0[y1, x0] + \
                    dy * dx * I0[y1, x1]
            err0 = f((<double>I_n[j, k] - W[j, k] * I0_bi) / sigma)

            y = (u[0, j, k] - di0) / ds_y
            x = (u[1, j, k] - dj0) / ds_x

            if y <= 0.0:
                dy = 0.0; y0 = 0; y1 = 0
            elif y >= Y0 - 1.0:
                dy = 0.0; y0 = Y0 - 1; y1 = Y0 - 1
            else:
                dy = y - floor(y)
                y0 = <int>floor(y); y1 = y0 + 1

            if x <= 0.0:
                dx = 0.0; x0 = 0; x1 = 0
            elif x >= X0 - 1.0:
                dx = 0.0; x0 = X0 - 1; x1 = X0 - 1
            else:
                dx = x - floor(x)
                x0 = <int>floor(x); x1 = x0 + 1

            I0_bi = (1.0 - dy) * (1.0 - dx) * I0[y0, x0] + \
                    (1.0 - dy) * dx * I0[y0, x1] + \
                    dy * (1.0 - dx) * I0[y1, x0] + \
                    dy * dx * I0[y1, x1]
            err1 = f((<double>I_n[j, k] - W[j, k] * I0_bi) / sigma)

            err += (errors[j, k] - err0 + err1)

    return err / (Y * X)

cdef void pm_gsearcher(uint_t[:, :, ::1] I_n, float_t[:, ::1] W, float_t[:, ::1] I0, float_t[:, :, ::1] u,
                       float_t[:, ::1] derrs, float_t[::1] di, float_t[::1] dj, int j, int k, double sw_y, double sw_x,
                       unsigned wsize, double ds_y, double ds_x, double sigma, loss_func f) nogil:
    cdef double err, err0, uy_min = 0.0, ux_min = 0.0, err_min=FLOAT_MAX, ux, uy 
    cdef double dsw_y = 2.0 * sw_y / (wsize - 1), dsw_x = 2.0 * sw_x / (wsize - 1)
    cdef int ii, jj

    err0 = FVU_interp(I_n, W[j, k], I0, di, dj, j, k, u[0, j, k],
                      u[1, j, k], ds_y, ds_x, sigma, f)

    for ii in range(<int>wsize if dsw_y > 0.0 else 1):
        uy = dsw_y * (ii - 0.5 * (wsize - 1))
        for jj in range(<int>wsize if dsw_x > 0.0 else 1):
            ux = dsw_x * (jj - 0.5 * (wsize - 1))
            err = FVU_interp(I_n, W[j, k], I0, di, dj, j, k, u[0, j, k] + uy,
                             u[1, j, k] + ux, ds_y, ds_x, sigma, f)

            if err < err_min:
                uy_min = uy; ux_min = ux; err_min = err

    u[0, j, k] += uy_min; u[1, j, k] += ux_min
    derrs[j, k] = err0 - err_min if err_min < err0 else 0.0

def pm_gsearch(uint_t[:, :, ::1] I_n not None, float_t[:, ::1] W not None, float_t[:, ::1] I0 not None,
               float_t[:, :, ::1] u0 not None, float_t[::1] di not None, float_t[::1] dj not None,
               double sw_y, double sw_x, unsigned grid_size, double ds_y, double ds_x, double sigma,
               str loss='Huber', unsigned num_threads=1):
    r"""Update the pixel mapping by minimizing mean-squared-error
    (MSE). Perform a grid search within the search window of `sw_y`,
    `sw_x` size along the vertical and fast axes accordingly in order to
    minimize the MSE at each point of the detector grid separately.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    I0 : numpy.ndarray
        Reference image of the sample.
    u0 : numpy.ndarray
        Initial pixel mapping.
    di : numpy.ndarray
        Sample's translations along the vertical detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    sw_y : float
        Search window size in pixels along the vertical detector
        axis.
    sw_x : float
        Search window size in pixels along the fast detector
        axis.
    grid_size : int
        Grid size along one of the detector axes. The grid shape is
        then (grid_size, grid_size).
    ds_y : float
        Sampling interval of reference image in pixels along the vertical axis.
    ds_x : float
        Sampling interval of reference image in pixels along the horizontal axis.
    sigma : float
        The standard deviation of :code:`I_n`.
    loss : {'Epsilon', 'Huber', 'L1', 'L2'}, optional
        Choose between the following loss functions:

        * 'Epsilon': Epsilon loss function (epsilon = 0.5)
        * 'Huber' : Huber loss function (k = 1.345)
        * 'L1' : L1 norm loss function.
        * 'L2' : L2 norm loss function.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    u : numpy.ndarray
        Updated pixel mapping array.
    derr : numpy.ndarray
        Error decrease for each pixel in the detector grid.
    """
    if ds_y <= 0.0 or ds_x <= 0.0:
        raise ValueError('Sampling intervals must be positive')

    cdef loss_func f = choose_loss(loss)

    cdef int type_num = np.PyArray_TYPE(W.base)
    cdef int Y = I_n.shape[1], X = I_n.shape[2], j, k

    cdef np.npy_intp *u_shape = [2, Y, X]
    cdef np.ndarray u = np.PyArray_SimpleNew(3, u_shape, type_num)
    cdef np.ndarray derr = np.PyArray_ZEROS(2, u_shape + 1, type_num, 0)
    cdef float_t[:, :, ::1] _u = u
    cdef float_t[:, ::1] _derr = derr

    for k in prange(X, schedule='guided', num_threads=num_threads, nogil=True):
        for j in range(Y):
            _u[0, j, k] = u0[0, j, k]; _u[1, j, k] = u0[1, j, k]
            if W[j, k] > 0.0:
                pm_gsearcher(I_n, W, I0, _u, _derr, di, dj, j, k, sw_y, sw_x,
                             grid_size, ds_y, ds_x, sigma, f)

    return u, derr

cdef void pm_rsearcher(uint_t[:, :, ::1] I_n, float_t[:, ::1] W, float_t[:, ::1] I0, gsl_rng *r, float_t[:, :, ::1] u,
                       float_t[:, ::1] derrs, float_t[::1] di, float_t[::1] dj, int j, int k, double sw_y, double sw_x,
                       unsigned N, double ds_y, double ds_x, double sigma, loss_func f) nogil:
    cdef double err, err0, err_min=FLOAT_MAX, uy_min = 0.0, ux_min = 0.0, ux, uy
    cdef int ii

    err0 = FVU_interp(I_n, W[j, k], I0, di, dj, j, k, u[0, j, k],
                      u[1, j, k], ds_y, ds_x, sigma, f)

    for ii in range(<int>N):
        uy = 2.0 * sw_y * (gsl_rng_uniform(r) - 0.5)
        ux = 2.0 * sw_x * (gsl_rng_uniform(r) - 0.5)

        err = FVU_interp(I_n, W[j, k], I0, di, dj, j, k, u[0, j, k] + uy,
                         u[1, j, k] + ux, ds_y, ds_x, sigma, f)
        if err < err_min:
            uy_min = uy; ux_min = ux; err_min = err

    u[0, j, k] += uy_min; u[1, j, k] += ux_min
    derrs[j, k] = err0 - err_min if err_min < err0 else 0.0

def pm_rsearch(uint_t[:, :, ::1] I_n not None, float_t[:, ::1] W not None, float_t[:, ::1] I0 not None,
               float_t[:, :, ::1] u0 not None, float_t[::1] di not None, float_t[::1] dj not None,
               double sw_y, double sw_x, unsigned n_trials, unsigned long seed, double ds_y, double ds_x, double sigma,
               str loss='Huber', unsigned num_threads=1):
    r"""Update the pixel mapping by minimizing mean-squared-error
    (MSE). Perform a random search within the search window of `sw_y`,
    `sw_x` size along the vertical and fast axes accordingly in order to
    minimize the MSE at each point of the detector grid separately.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    I0 : numpy.ndarray
        Reference image of the sample.
    u0 : numpy.ndarray
        Initial pixel mapping.
    di : numpy.ndarray
        Sample's translations along the vertical detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    sw_y : float
        Search window size in pixels along the vertical detector
        axis.
    sw_x : float
        Search window size in pixels along the horizontal detector
        axis.
    n_trials : int
        Number of points generated at each pixel of the detector grid.
    seed : int
        Specify seed for the random number generation.
    ds_y : float
        Sampling interval of reference image in pixels along the vertical axis.
    ds_x : float
        Sampling interval of reference image in pixels along the horizontal axis.
    sigma : float
        The standard deviation of :code:`I_n`.
    loss : {'Epsilon', 'Huber', 'L1', 'L2'}, optional
        Choose between the following loss functions:

        * 'Epsilon': Epsilon loss function (epsilon = 0.5)
        * 'Huber' : Huber loss function (k = 1.345)
        * 'L1' : L1 norm loss function.
        * 'L2' : L2 norm loss function.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    u : numpy.ndarray
        Updated pixel mapping array.
    derr : numpy.ndarray
        Error decrease for each pixel in the detector grid.
    """
    if ds_y <= 0.0 or ds_x <= 0.0:
        raise ValueError('Sampling intervals must be positive')

    cdef loss_func f = choose_loss(loss)

    cdef int type_num = np.PyArray_TYPE(W.base)
    cdef int Y = I_n.shape[1], X = I_n.shape[2], j, k

    cdef np.npy_intp *u_shape = [2, Y, X]
    cdef np.ndarray u = np.PyArray_SimpleNew(3, u_shape, type_num)
    cdef np.ndarray derr = np.PyArray_ZEROS(2, u_shape + 1, type_num, 0)
    cdef float_t[:, :, ::1] _u = u
    cdef float_t[:, ::1] _derr = derr

    cdef gsl_rng *r_master = gsl_rng_alloc(gsl_rng_mt19937)
    gsl_rng_set(r_master, seed)
    cdef unsigned long thread_seed
    cdef gsl_rng *r

    with nogil, parallel(num_threads=num_threads):
        r = gsl_rng_alloc(gsl_rng_mt19937)
        thread_seed = gsl_rng_get(r_master)
        gsl_rng_set(r, thread_seed)

        for k in prange(X, schedule='guided'):
            for j in range(Y):
                _u[0, j, k] = u0[0, j, k]; _u[1, j, k] = u0[1, j, k]
                if W[j, k] > 0.0:
                    pm_rsearcher(I_n, W, I0, r, _u, _derr, di, dj, j, k, sw_y, sw_x,
                                 n_trials, ds_y, ds_x, sigma, f)

        gsl_rng_free(r)

    gsl_rng_free(r_master)

    return u, derr

cdef void pm_devolver(uint_t[:, :, ::1] I_n, float_t[:, ::1] W, float_t[:, ::1] I0, gsl_rng *r, float_t[:, :, ::1] u,
                      float_t[:, ::1] derrs, float_t[::1] di, float_t[::1] dj, int j, int k, double sw_y, double sw_x,
                      unsigned NP, unsigned n_iter, double CR, double F, double ds_y, double ds_x, double sigma, loss_func f) nogil:
    cdef double err0, err, err_min = FLOAT_MAX
    cdef int ii, jj, n, a, b
    cdef double u_min[2]
    cdef double sw[2]
    cdef double *pop = <double *>malloc(2 * NP * sizeof(double))
    cdef double *cost = <double *>malloc(NP * sizeof(double))
    cdef double *new_pop = <double *>malloc(2 * NP * sizeof(double))

    sw[0] = sw_y; sw[1] = sw_x
    err0 = FVU_interp(I_n, W[j, k], I0, di, dj, j, k, u[0, j, k],
                      u[1, j, k], ds_y, ds_x, sigma, f)

    for ii in range(<int>NP):
        pop[2 * ii] = 2.0 * sw_y * (gsl_rng_uniform(r) - 0.5)
        pop[2 * ii + 1] = 2.0 * sw_x * (gsl_rng_uniform(r) - 0.5)

        cost[ii] = FVU_interp(I_n, W[j, k], I0, di, dj, j, k, u[0, j, k] + pop[2 * ii],
                             u[1, j, k] + pop[2 * ii + 1], ds_y, ds_x, sigma, f)
        
        if cost[ii] < err_min:
            u_min[0] = pop[2 * ii]; u_min[1] = pop[2 * ii + 1]; err_min = cost[ii]

    for n in range(<int>n_iter):
        for ii in range(<int>NP):
            a = gsl_rng_uniform_int(r, NP)
            while a == ii:
                a = gsl_rng_uniform_int(r, NP)
            
            b = gsl_rng_uniform_int(r, NP)
            while b == ii or b == a:
                b = gsl_rng_uniform_int(r, NP)

            jj = gsl_rng_uniform_int(r, 2)
            if gsl_rng_uniform(r) < CR:
                new_pop[2 * ii + jj] = u_min[jj] + F * (pop[2 * a + jj] - pop[2 * b + jj])
                if new_pop[2 * ii + jj] > sw[jj]: new_pop[2 * ii + jj] = sw[jj]
                if new_pop[2 * ii + jj] < -sw[jj]: new_pop[2 * ii + jj] = -sw[jj]
            else:
                new_pop[2 * ii + jj] = pop[2 * ii + jj]
            jj = (jj + 1) % 2
            new_pop[2 * ii + jj] = u_min[jj] + F * (pop[2 * a + jj] - pop[2 * b + jj])
            if new_pop[2 * ii + jj] > sw[jj]: new_pop[2 * ii + jj] = sw[jj]
            if new_pop[2 * ii + jj] < -sw[jj]: new_pop[2 * ii + jj] = -sw[jj]

            err = FVU_interp(I_n, W[j, k], I0, di, dj, j, k, u[0, j, k] + new_pop[2 * ii],
                             u[1, j, k] + new_pop[2 * ii + 1], ds_y, ds_x, sigma, f)

            if err < cost[ii]:
                cost[ii] = err
                if err < err_min:
                    u_min[0] = new_pop[2 * ii]; u_min[1] = new_pop[2 * ii + 1]; err_min = err
            else:
                new_pop[2 * ii] = pop[2 * ii]; new_pop[2 * ii + 1] = pop[2 * ii + 1]
            
        for ii in range(2 * <int>NP):
            pop[ii] = new_pop[ii]

    free(pop); free(new_pop); free(cost)

    u[0, j, k] += u_min[0]; u[1, j, k] += u_min[1]
    derrs[j, k] = err0 - err_min if err_min < err0 else 0.0

def pm_devolution(uint_t[:, :, ::1] I_n not None, float_t[:, ::1] W not None, float_t[:, ::1] I0 not None,
                  float_t[:, :, ::1] u0 not None, float_t[::1] di not None, float_t[::1] dj not None,
                  double sw_y, double sw_x, unsigned pop_size, unsigned n_iter, unsigned long seed,
                  double ds_y, double ds_x, double sigma, double F=0.75, double CR=0.7, str loss='Huber',
                  unsigned num_threads=1):
    r"""Update the pixel mapping by minimizing mean-squared-error
    (MSE). Perform a differential evolution within the search window of `sw_y`,
    `sw_x` size along the vertical and fast axes accordingly in order to
    minimize the MSE at each point of the detector grid separately.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    I0 : numpy.ndarray
        Reference image of the sample.
    u0 : numpy.ndarray
        Initial pixel mapping.
    di : numpy.ndarray
        Sample's translations along the vertical detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    sw_y : float
        Search window size in pixels along the vertical detector
        axis.
    sw_x : float
        Search window size in pixels along the horizontal detector
        axis.
    pop_size : int
        The total population size. Must be greater or equal to 4.
    n_iter : int
        The maximum number of generations over which the entire population
        is evolved.
    seed : int
        Specify seed for the random number generation.
    ds_y : float
        Sampling interval of reference image in pixels along the vertical axis.
    ds_x : float
        Sampling interval of reference image in pixels along the horizontal axis.
    sigma : float
        The standard deviation of :code:`I_n`.
    F : float, optional
        The mutation constant. In the literature this is also known as
        differential weight. If specified as a float it should be in the
        range [0, 2].
    CR : float, optional
        The recombination constant, should be in the range [0, 1]. In the
        literature this is also known as the crossover probability.
    loss : {'Epsilon', 'Huber', 'L1', 'L2'}, optional
        Choose between the following loss functions:

        * 'Epsilon': Epsilon loss function (epsilon = 0.5)
        * 'Huber' : Huber loss function (k = 1.345)
        * 'L1' : L1 norm loss function.
        * 'L2' : L2 norm loss function.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    u : numpy.ndarray
        Updated pixel mapping array.
    derr : numpy.ndarray
        Error decrease for each pixel in the detector grid.
    """
    if ds_y <= 0.0 or ds_x <= 0.0:
        raise ValueError('Sampling intervals must be positive')
    if pop_size < 4:
        raise ValueError('Population size must be greater or equal to 4.')
    if F < 0.0 or F > 2.0:
        raise ValueError('The mutation constant F must be in the interval [0.0, 2.0].')
    if CR < 0.0 or CR > 1.0:
        raise ValueError('The recombination constant CR must be in the interval [0.0, 1.0].')

    cdef loss_func f = choose_loss(loss)

    cdef int type_num = np.PyArray_TYPE(W.base)
    cdef int Y = I_n.shape[1], X = I_n.shape[2], j, k

    cdef np.npy_intp *u_shape = [2, Y, X]
    cdef np.ndarray u = np.PyArray_SimpleNew(3, u_shape, type_num)
    cdef np.ndarray derr = np.PyArray_ZEROS(2, u_shape + 1, type_num, 0)
    cdef float_t[:, :, ::1] _u = u
    cdef float_t[:, ::1] _derr = derr

    cdef gsl_rng *r_master = gsl_rng_alloc(gsl_rng_mt19937)
    gsl_rng_set(r_master, seed)
    cdef unsigned long thread_seed
    cdef gsl_rng *r

    with nogil, parallel(num_threads=num_threads):
        r = gsl_rng_alloc(gsl_rng_mt19937)
        thread_seed = gsl_rng_get(r_master)
        gsl_rng_set(r, thread_seed)

        for k in prange(X, schedule='guided'):
            for j in range(Y):
                _u[0, j, k] = u0[0, j, k]; _u[1, j, k] = u0[1, j, k]
                if W[j, k] > 0.0:
                    pm_devolver(I_n, W, I0, r, _u, _derr, di, dj, j, k, sw_y, sw_x,
                                pop_size, n_iter, CR, F, ds_y, ds_x, sigma, f)

        gsl_rng_free(r)

    gsl_rng_free(r_master)

    return u, derr

cdef void tr_updater(float_t[:, ::1] errors, uint_t[:, ::1] I_n, float_t[:, ::1] W, float_t[:, ::1] I0,
                     float_t[:, :, ::1] u, float_t *di, float_t *dj, double sw_y, double sw_x,
                     unsigned wsize, double ds_y, double ds_x, double sigma, loss_func f) nogil:
    cdef double di_min = 0.0, dj_min = 0.0, err_min=FLOAT_MAX, dii, djj
    cdef double dsw_y = 2.0 * sw_y / (wsize - 1), dsw_x = 2.0 * sw_x / (wsize - 1)
    cdef int ii, jj

    for ii in range(<int>wsize if dsw_y > 0.0 else 1):
        dii = dsw_y * (ii - 0.5 * (wsize - 1))
        for jj in range(<int>wsize if dsw_x > 0.0 else 1):
            djj = dsw_x * (jj - 0.5 * (wsize - 1))
            err = FVU_interp_tr(errors, I_n, W, I0, u, di[0], dj[0],
                                di[0] + dii, dj[0] + djj, ds_y, ds_x, sigma, f)

            if err < err_min:
                di_min = dii; dj_min = djj; err_min = err

    di[0] += di_min; dj[0] += dj_min

def tr_gsearch(uint_t[:, :, ::1] I_n not None, float_t[:, ::1] W not None, float_t[:, ::1] I0 not None,
               float_t[:, :, ::1] u not None, float_t[::1] di not None, float_t[::1] dj not None,
               double sw_y, double sw_x, unsigned grid_size, double ds_y, double ds_x, double sigma,
               str loss='Huber', unsigned num_threads=1) -> np.ndarray:
    r"""Update the sample pixel translations by minimizing total mean-squared-error
    (:math:$MSE_{total}$). Perform a grid search within the search window of
    `sw_y` size in pixels for sample translations along the vertical axis, and
    of `sw_x` size in pixels for sample translations along the horizontal axis in
    order to minimize the total MSE.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    I0 : numpy.ndarray
        Reference image of the sample.
    u : numpy.ndarray
        The pixel mapping between the data at
        the detector plane and the reference image at
        the reference plane.
    di : numpy.ndarray
        Initial sample's translations along the vertical detector
        axis in pixels.
    dj : numpy.ndarray
        Initial sample's translations along the fast detector
        axis in pixels.
    sw_y : float
        Search window size in pixels along the vertical detector
        axis.
    sw_x : float
        Search window size in pixels along the fast detector
        axis.
    grid_size : int
        Grid size along one of the detector axes. The grid shape is
        then (grid_size, grid_size).
    ds_y : float
        Sampling interval of reference image in pixels along the vertical axis.
    ds_x : float
        Sampling interval of reference image in pixels along the horizontal axis.
    sigma : float
        The standard deviation of :code:`I_n`.
    loss : {'Epsilon', 'Huber', 'L1', 'L2'}, optional
        Choose between the following loss functions:

        * 'Epsilon': Epsilon loss function (epsilon = 0.5)
        * 'Huber' : Huber loss function (k = 1.345)
        * 'L1' : L1 norm loss function.
        * 'L2' : L2 norm loss function.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    dij : numpy.ndarray
        Updated sample pixel translations.

    Notes
    -----
    The following error metric is being minimized:

    .. math::

        MSE_{total} = \frac{1}{N M}\sum_{i, j} \left( \frac{\sum_{n}
        \left( I_g[n] - I_{ref}[ii_n, jj_n] \right)^2}{\sum_{n}
        \left(I_g[n] - 1 \right)^2} \right)
    
    Where :math:`I_g[n]` is a smoothed intensity profile of the
    particular detector coordinate :math:`I_n[n, i, j]`. Intensity
    profile :math:`I_n[n, i, j]` is smoothed with gaussian kernel
    :math:`\phi`:

    .. math::
        I_g[n] = \frac{\sum_{\Delta i, \Delta j} I_n[n, i + \Delta i,
        j + \Delta j] W[i + \Delta i, j + \Delta j] 
        \phi[\Delta u[0], \Delta u[1]]}
        {\sum_{\Delta i, \Delta j} W[i + \Delta i, j + \Delta j]^2
        \phi[\Delta u[0], \Delta u[1]]}
    
    .. math::
        \Delta u[0] = u[0, i + \Delta i, j + \Delta j] - u[0, i, j]
    
    .. math::
        \Delta u[1] = u[1, i + \Delta i, j + \Delta j] - u[1, i, j]

    .. math::
        \phi [\Delta ii_{ref}, \Delta jj_{ref}] = 
        \exp\left[{-\frac{(\Delta ii_{ref})^2 + 
        (\Delta jj_{ref})^2}{ls^2}}\right]
    """
    if ds_y <= 0.0 or ds_x <= 0.0:
        raise ValueError('Sampling intervals must be positive')

    cdef loss_func f = choose_loss(loss)

    cdef int type_num = np.PyArray_TYPE(W.base)
    cdef int N = I_n.shape[0], Y = I_n.shape[1], X = I_n.shape[2], i, j, k

    cdef np.npy_intp *buf_shape = [Y, X]
    cdef float_t[:, ::1] errors = np.PyArray_SimpleNew(2, buf_shape, type_num)

    cdef np.npy_intp *dij_shape = [N, 2]
    cdef np.ndarray dij = np.PyArray_SimpleNew(2, dij_shape, type_num)
    cdef float_t[:, ::1] _dij = dij

    for k in prange(X, schedule='guided', num_threads=num_threads, nogil=True):
        for j in range(Y):
            if W[j, k] > 0.0:
                errors[j, k] = FVU_interp(I_n, W[j, k], I0, di, dj, j, k,
                                          u[0, j, k], u[1, j, k], ds_y, ds_x, sigma, f)
            else:
                errors[j, k] = 0.0

    for i in prange(N, schedule='guided', num_threads=num_threads, nogil=True):
        _dij[i, 0] = di[i]; _dij[i, 1] = dj[i]
        tr_updater(errors, I_n[i], W, I0, u, &_dij[i, 0], &_dij[i, 1],
                   sw_y, sw_x, grid_size, ds_y, ds_x, sigma, f)

    return dij

def pm_errors(uint_t[:, :, ::1] I_n not None, float_t[:, ::1] W not None, float_t[:, ::1] I0 not None,
              float_t[:, :, ::1] u not None, float_t[::1] di not None, float_t[::1] dj not None,
              double ds_y, double ds_x, double sigma, str loss='Huber', unsigned num_threads=1) -> np.ndarray:
    """Return the residuals for the pixel mapping fit.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    I0 : numpy.ndarray
        Reference image of the sample.
    u : numpy.ndarray
        The pixel mapping between the data at
        the detector plane and the reference image at
        the reference plane.
    di : numpy.ndarray
        Sample's translations along the vertical detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    ds_y : float
        Sampling interval of reference image in pixels along the vertical axis.
    ds_x : float
        Sampling interval of reference image in pixels along the horizontal axis.
    sigma : float
        The standard deviation of :code:`I_n`.
    loss : {'Epsilon', 'Huber', 'L1', 'L2'}, optional
        Choose between the following loss functions:

        * 'Epsilon': Epsilon loss function (epsilon = 0.5)
        * 'Huber' : Huber loss function (k = 1.345)
        * 'L1' : L1 norm loss function.
        * 'L2' : L2 norm loss function.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    errors : numpy.ndarray
        Residuals of the pixel mapping fit.

    See Also
    --------
    pm_gsearch : Description of error metric which
        is being minimized.
    """
    if ds_y <= 0.0 or ds_x <= 0.0:
        raise ValueError('Sampling intervals must be positive')

    cdef loss_func f = choose_loss(loss)

    cdef int type_num = np.PyArray_TYPE(W.base)
    cdef int Y = I_n.shape[1], X = I_n.shape[2], j, k

    cdef np.ndarray errs = np.PyArray_SimpleNew(2, <np.npy_intp *>I_n.shape + 1, type_num)
    cdef float_t[:, ::1] _errs = errs

    for k in prange(X, schedule='guided', num_threads=num_threads, nogil=True):
        for j in range(Y):
            if W[j, k] > 0.0:
                _errs[j, k] = FVU_interp(I_n, W[j, k], I0, di, dj, j, k,
                                         u[0, j, k], u[1, j, k], ds_y, ds_x, sigma, f)
            else:
                _errs[j, k] = 0.0

    return errs

def pm_total_error(uint_t[:, :, ::1] I_n not None, float_t[:, ::1] W not None, float_t[:, ::1] I0 not None,
                   float_t[:, :, ::1] u not None, float_t[::1] di not None, float_t[::1] dj not None,
                   double ds_y, double ds_x, double sigma, str loss='Huber', unsigned num_threads=1) -> double:
    """Return the mean residual for the pixel mapping fit.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    I0 : numpy.ndarray
        Reference image of the sample.
    u : numpy.ndarray
        The pixel mapping between the data at
        the detector plane and the reference image at
        the reference plane.
    di : numpy.ndarray
        Sample's translations along the vertical detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    ds_y : float
        Sampling interval of reference image in pixels along the vertical axis.
    ds_x : float
        Sampling interval of reference image in pixels along the horizontal axis.
    sigma : float
        The standard deviation of :code:`I_n`.
    loss : {'Epsilon', 'Huber', 'L1', 'L2'}, optional
        Choose between the following loss functions:

        * 'Epsilon': Epsilon loss function (epsilon = 0.5)
        * 'Huber' : Huber loss function (k = 1.345)
        * 'L1' : L1 norm loss function.
        * 'L2' : L2 norm loss function.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    err : numpy.ndarray
        Mean residual value of the pixel mapping fit.

    See Also
    --------
    pm_gsearch : Description of error metric which
        is being minimized.
    """
    if ds_y <= 0.0 or ds_x <= 0.0:
        raise ValueError('Sampling intervals must be positive')

    cdef loss_func f = choose_loss(loss)

    cdef int type_num = np.PyArray_TYPE(W.base)
    cdef int Y = I_n.shape[1], X = I_n.shape[2], j, k
    cdef double err

    for k in prange(X, schedule='guided', num_threads=num_threads, nogil=True):
        for j in range(Y):
            if W[j, k] > 0.0:
                err += FVU_interp(I_n, W[j, k], I0, di, dj, j, k,
                                  u[0, j, k], u[1, j, k], ds_y, ds_x, sigma, f)

    return err / (X * Y)

cdef void FVU_frame(float_t[:, ::1] errors, float_t[:, ::1] R, float_t[:, ::1] I0,
                    uint_t[:, ::1] I_n, float_t[:, ::1] W, float_t[:, :, ::1] u, float_t di, float_t dj,
                    double ds_y, double ds_x, double h, double sigma, loss_func f) nogil:
    cdef int Y = I_n.shape[0], X = I_n.shape[1]
    cdef int j, k, jj, kk, j0, k0, jj0, jj1, kk0, kk1
    cdef int Y0 = I0.shape[0], X0 = I0.shape[1]
    cdef int dn_y = <int>ceil((4.0 * h) / ds_y), dn_x = <int>ceil((4.0 * h) / ds_x)
    cdef double y, x, r, I

    for j in range(Y):
        for k in range(X):
            y = u[0, j, k] - di
            x = u[1, j, k] - dj

            j0 = <int>(y / ds_y) + 1
            k0 = <int>(x / ds_x) + 1

            jj0 = j0 - dn_y if j0 - dn_y > 0 else 0
            jj1 = j0 + dn_y if j0 + dn_y < Y0 else Y0
            kk0 = k0 - dn_x if k0 - dn_x > 0 else 0
            kk1 = k0 + dn_x if k0 + dn_x < X0 else X0

            for jj in range(jj0, jj1):
                for kk in range(kk0, kk1):
                    r = rbf((ds_y * jj - y) * (ds_y * jj - y) + (ds_x * kk - x) * (ds_x * kk - x), h)
                    errors[jj, kk] += r * f((<double>I_n[j, k] - W[j, k] * I0[jj, kk]) / sigma)
                    R[jj, kk] += r

def ref_errors(uint_t[:, :, ::1] I_n not None, float_t[:, ::1] W not None, float_t[:, ::1] I0 not None,
               float_t[:, :, ::1] u not None, float_t[::1] di not None, float_t[::1] dj not None,
               double ds_y, double ds_x, double h, double sigma, str loss='Huber', unsigned num_threads=1) -> np.ndarray:
    """Return the residuals for the reference image regression.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    I0 : numpy.ndarray
        Reference image of the sample.
    u : numpy.ndarray
        The pixel mapping between the data at
        the detector plane and the reference image at
        the reference plane.
    di : numpy.ndarray
        Sample's translations along the vertical detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    ds_y : float
        Sampling interval of reference image in pixels along the vertical axis.
    ds_x : float
        Sampling interval of reference image in pixels along the horizontal axis.
    h : float
        Kernel bandwidth in pixels.
    sigma : float
        The standard deviation of :code:`I_n`.
    loss : {'Epsilon', 'Huber', 'L1', 'L2'}, optional
        Choose between the following loss functions:

        * 'Epsilon': Epsilon loss function (epsilon = 0.5)
        * 'Huber' : Huber loss function (k = 1.345)
        * 'L1' : L1 norm loss function.
        * 'L2' : L2 norm loss function.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    errors : numpy.ndarray
        Residuals array of the reference image regression.

    See Also
    --------
    KR_reference : Description of error metric which
        is being minimized.
    """
    if ds_y <= 0.0 or ds_x <= 0.0:
        raise ValueError('Sampling intervals must be positive')

    cdef loss_func f = choose_loss(loss)

    cdef int type_num = np.PyArray_TYPE(W.base)
    cdef int N = I_n.shape[0], Y0 = I0.shape[0], X0 = I0.shape[1]
    cdef int i, j, k, t
        
    cdef np.npy_intp *shape = [num_threads, Y0, X0]
    cdef float_t[:, :, ::1] err_buf = np.PyArray_ZEROS(3, shape, type_num, 0)
    cdef float_t[:, :, ::1] R_buf = np.PyArray_ZEROS(3, shape, type_num, 0)
    cdef np.ndarray err = np.PyArray_SimpleNew(2, shape + 1, type_num)

    for i in prange(N, schedule='guided', num_threads=num_threads, nogil=True):
        t = openmp.omp_get_thread_num()
        FVU_frame(err_buf[t], R_buf[t], I0, I_n[i], W, u, di[i], dj[i],
                  ds_y, ds_x, h, sigma, f)

    cdef float_t[:, ::1] _err = err
    cdef float_t err_sum, R_sum
    for k in prange(X0, schedule='guided', num_threads=num_threads, nogil=True):
        for j in range(Y0):
            err_sum = 0.0; R_sum = 0.0
            for i in range(<int>num_threads):
                err_sum = err_sum + err_buf[i, j, k]
                R_sum = R_sum + R_buf[i, j, k]

            _err[j, k] = err_sum / R_sum if R_sum > 0.0 else 0.0

    return err

def ref_total_error(uint_t[:, :, ::1] I_n not None, float_t[:, ::1] W not None, float_t[:, ::1] I0 not None,
                    float_t[:, :, ::1] u not None, float_t[::1] di not None, float_t[::1] dj not None,
                    double ds_y, double ds_x, double h, double sigma, str loss='Huber', unsigned num_threads=1):
    """Return the mean residual for the reference image regression.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    I0 : numpy.ndarray
        Reference image of the sample.
    u : numpy.ndarray
        The pixel mapping between the data at
        the detector plane and the reference image at
        the reference plane.
    di : numpy.ndarray
        Sample's translations along the vertical detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    ds_y : float
        Sampling interval of reference image in pixels along the vertical axis.
    ds_x : float
        Sampling interval of reference image in pixels along the horizontal axis.
    h : float
        Kernel bandwidth in pixels.
    sigma : float
        The standard deviation of :code:`I_n`.
    loss : {'Epsilon', 'Huber', 'L1', 'L2'}, optional
        Choose between the following loss functions:

        * 'Epsilon': Epsilon loss function (epsilon = 0.5)
        * 'Huber' : Huber loss function (k = 1.345)
        * 'L1' : L1 norm loss function.
        * 'L2' : L2 norm loss function.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    err : float
        Mean residual value.

    See Also
    --------
    KR_reference : Description of error metric which
        is being minimized.
    """
    if ds_y <= 0.0 or ds_x <= 0.0:
        raise ValueError('Sampling intervals must be positive')

    cdef loss_func f = choose_loss(loss)

    cdef int type_num = np.PyArray_TYPE(W.base)
    cdef int N = I_n.shape[0], Y0 = I0.shape[0], X0 = I0.shape[1]
    cdef int i, j, t, k
        
    cdef np.npy_intp *shape = [num_threads, Y0, X0]
    cdef float_t[:, :, ::1] err_buf = np.PyArray_ZEROS(3, shape, type_num, 0)
    cdef float_t[:, :, ::1] R_buf = np.PyArray_ZEROS(3, shape, type_num, 0)

    for i in prange(N, schedule='guided', num_threads=num_threads, nogil=True):
        t = openmp.omp_get_thread_num()
        FVU_frame(err_buf[t], R_buf[t], I0, I_n[i], W, u, di[i], dj[i],
                  ds_y, ds_x, h, sigma, f)

    cdef double err = 0.0, err2 = 0.0
    cdef double err_sum, R_sum, err_jk
    for k in prange(X0, schedule='guided', num_threads=num_threads, nogil=True):
        for j in range(Y0):
            err_sum = 0.0; R_sum = 0.0
            for i in range(<int>num_threads):
                err_sum = err_sum + err_buf[i, j, k]
                R_sum = R_sum + R_buf[i, j, k]

            if R_sum > 0.0:
                err_jk = err_sum / R_sum
                err += err_jk
                err2 += err_jk * err_jk

    err /= (X0 * Y0)
    err2 /= (X0 * Y0)

    return err, sqrt(err2 - err * err)

def ct_integrate(float_t[:, ::1] sy_arr not None, float_t[:, ::1] sx_arr not None, int num_threads=1) -> np.ndarray:
    """Perform the Fourier Transform wavefront reconstruction [FTI]_
    with antisymmetric derivative integration [ASDI]_.

    Parameters
    ----------
    sx_arr : numpy.ndarray
        Array of gradient values along the horizontal axis.
    sy_arr : numpy.ndarray
        Array of gradient values along the vertical axis.
    num_threads : int, optional
        Number of threads.

    Returns
    -------
    w : numpy.ndarray
        Reconstructed wavefront.

    References
    ----------
    .. [FTI] C. Kottler, C. David, F. Pfeiffer, and O. Bunk,
             "A two-directional approach for grating based
             differential phase contrast imaging using hard x-rays,"
             Opt. Express 15, 1175-1181 (2007).
    .. [ASDI] Pierre Bon, Serge Monneret, and Benoit Wattellier,
              "Noniterative boundary-artifact-free wavefront
              reconstruction from its derivatives," Appl. Opt. 51,
              5698-5704 (2012).
    """
    cdef int type_num = np.PyArray_TYPE(sx_arr.base)
    cdef np.npy_intp a = sx_arr.shape[0], b = sx_arr.shape[1]
    cdef int i, j, ii, jj
    cdef np.npy_intp *asdi_shape = [2 * a, 2 * b]
    
    cdef np.ndarray[np.complex128_t, ndim=2] sfy_asdi = np.PyArray_SimpleNew(2, asdi_shape, np.NPY_COMPLEX128)
    cdef pyfftw.FFTW fftw_obj = pyfftw.FFTW(sfy_asdi, sfy_asdi, axes=(0, 1), threads=num_threads)
    for i in range(a):
        for j in range(b):
            sfy_asdi[i, j] = -sy_arr[a - i - 1, b - j - 1]
    for i in range(a):
        for j in range(b):
            sfy_asdi[i + a, j] = sy_arr[i, b - j - 1]
    for i in range(a):
        for j in range(b):
            sfy_asdi[i, j + b] = -sy_arr[a - i - 1, j]
    for i in range(a):
        for j in range(b):
            sfy_asdi[i + a, j + b] = sy_arr[i, j]
    fftw_obj._execute()

    cdef np.ndarray[np.complex128_t, ndim=2] sfx_asdi = np.PyArray_SimpleNew(2, asdi_shape, np.NPY_COMPLEX128)
    fftw_obj._update_arrays(sfx_asdi, sfx_asdi)
    for i in range(a):
        for j in range(b):
            sfx_asdi[i, j] = -sx_arr[a - i - 1, b - j - 1]
    for i in range(a):
        for j in range(b):
            sfx_asdi[i + a, j] = -sx_arr[i, b - j - 1]
    for i in range(a):
        for j in range(b):
            sfx_asdi[i, j + b] = sx_arr[a - i - 1, j]
    for i in range(a):
        for j in range(b):
            sfx_asdi[i + a, j + b] = sx_arr[i, j]
    fftw_obj._execute()

    cdef pyfftw.FFTW ifftw_obj = pyfftw.FFTW(sfx_asdi, sfx_asdi, direction='FFTW_BACKWARD', axes=(0, 1), threads=num_threads)
    cdef double xf, yf, norm = 1.0 / <double>np.PyArray_SIZE(sfx_asdi)
    for i in range(2 * a):
        yf = 0.5 * <double>i / a - i // a
        for j in range(2 * b):
            xf = 0.5 * <double>j / b - j // b
            sfx_asdi[i, j] = norm * (sfy_asdi[i, j] * yf + sfx_asdi[i, j] * xf) / (2j * pi * (xf * xf + yf * yf))
    sfx_asdi[0, 0] = 0.0 + 0.0j
    ifftw_obj._execute()

    return np.asarray(sfx_asdi.real[a:, b:], dtype=sx_arr.base.dtype)