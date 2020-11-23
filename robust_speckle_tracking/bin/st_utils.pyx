cimport numpy as np
import numpy as np
from cython_gsl cimport *
from libc.math cimport sqrt, exp, pi, floor
from cython.parallel import prange
cimport openmp
from posix.time cimport clock_gettime, timespec, CLOCK_REALTIME
from pyfftw import FFTW, empty_aligned

ctypedef fused float_t:
    np.float64_t
    np.float32_t

ctypedef np.uint64_t uint_t
ctypedef np.npy_bool bool_t

DEF FLOAT_MAX = 1.7976931348623157e+308
DEF MU_C = 1.681792830507429
DEF NO_VAR = -1.0

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

cdef float_t rbf(float_t dsq, float_t ls) nogil:
    return exp(-dsq / 2 / ls**2) / sqrt(2 * pi)

cdef void frame_reference(float_t[:, ::1] I0, float_t[:, ::1] w0, float_t[:, ::1] I, float_t[:, ::1] W,
                          float_t[:, :, ::1] u, float_t di, float_t dj, float_t ls) nogil:
    cdef:
        int b = I.shape[0], c = I.shape[1], j, k, jj, kk, j0, k0
        int aa = I0.shape[0], bb = I0.shape[1], jj0, jj1, kk0, kk1
        int dn = <int>(ceil(4 * ls))
        float_t ss, fs, r
    for j in range(b):
        for k in range(c):
            ss = u[0, j, k] - di
            fs = u[1, j, k] - dj
            j0 = <int>(ss) + 1
            k0 = <int>(fs) + 1
            jj0 = j0 - dn if j0 - dn > 0 else 0
            jj1 = j0 + dn if j0 + dn < aa else aa
            kk0 = k0 - dn if k0 - dn > 0 else 0
            kk1 = k0 + dn if k0 + dn < bb else bb
            for jj in range(jj0, jj1):
                for kk in range(kk0, kk1):
                    r = rbf((jj - ss)**2 + (kk - fs)**2, ls)
                    I0[jj, kk] += I[j, k] * W[j, k] * r
                    w0[jj, kk] += W[j, k]**2 * r

def make_reference(float_t[:, :, ::1] I_n, float_t[:, ::1] W, float_t[:, :, ::1] u, float_t[::1] di,
                   float_t[::1] dj, int sw_ss, int sw_fs, float_t ls, bool_t return_nm0=True):
    r"""Generate an unabberated reference image of the sample
    based on the pixel mapping `u` and the measured data `I_n`
    using the `simple kriging`_.

    .. _simple kriging: https://en.wikipedia.org/wiki/Kriging#Simple_kriging

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    u : numpy.ndarray
        The pixel mapping between the data at
        the detector's plane and the reference image at
        the reference plane.
    di : numpy.ndarray
        Sample's translations along the slow detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    sw_ss : int
        Search window size in pixels along the slow detector
        axis.
    sw_fs : int
        Search window size in pixels along the fast detector
        axis.
    ls : float
        Reference image length scale in pixels.
    return_nm0 : bool
        If True, also returns the lower bounds (`n0`, `m0`)
        of the reference image in pixels.

    Returns
    -------
    I0 : numpy.ndarray
        Reference image array.
    n0 : int, optional
        The lower bounds of the slow detector axis of
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
    simply kriging approach with the gaussian radial basis
    function :math:`\phi`:

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
    dtype = np.float64 if float_t is np.float64_t else np.float32
    cdef:
        int a = I_n.shape[0], b = I_n.shape[1], c = I_n.shape[2], i, j, k, t
        float_t n0 = -min_float(&u[0, 0, 0], b * c) + max_float(&di[0], a) + sw_ss
        float_t m0 = -min_float(&u[1, 0, 0], b * c) + max_float(&dj[0], a) + sw_fs
        int aa = <int>(max_float(&u[0, 0, 0], b * c) - min_float(&di[0], a) + n0) + 1 + sw_ss
        int bb = <int>(max_float(&u[1, 0, 0], b * c) - min_float(&dj[0], a) + m0) + 1 + sw_fs
        int max_threads = openmp.omp_get_max_threads()
        float_t[:, :, ::1] I = np.zeros((max_threads, aa, bb), dtype=dtype)
        float_t[:, :, ::1] w = np.zeros((max_threads, aa, bb), dtype=dtype)
        float_t[::1] Is = np.empty(max_threads, dtype=dtype)
        float_t[::1] ws = np.empty(max_threads, dtype=dtype)
        float_t[:, ::1] I0 = np.zeros((aa, bb), dtype=dtype)
    for i in prange(a, schedule='guided', nogil=True):
        t = openmp.omp_get_thread_num()
        frame_reference(I[t], w[t], I_n[i], W, u, di[i] - n0, dj[i] - m0, ls)
    for k in prange(bb, schedule='guided', nogil=True):
        t = openmp.omp_get_thread_num()
        for j in range(aa):
            Is[t] = 0; ws[t] = 0
            for i in range(max_threads):
                Is[t] = Is[t] + I[i, j, k]
                ws[t] = ws[t] + w[i, j, k]
            if ws[t]:
                I0[j, k] = Is[t] / ws[t]
            else:
                I0[j, k] = 0
    if return_nm0:
        return np.asarray(I0), <int>(n0), <int>(m0)
    else:
        return np.asarray(I0)

cdef void mse_bi(float_t* m_ptr, float_t[::1] I, float_t[:, ::1] I0,
                 float_t[::1] di, float_t[::1] dj, float_t ux, float_t uy) nogil:
    cdef:
        int a = I.shape[0] - 1, aa = I0.shape[0], bb = I0.shape[1]
        int i, ss0, ss1, fs0, fs1
        float_t SS_res = 0, SS_tot = 0, ss, fs, dss, dfs, I0_bi
    for i in range(a):
        ss = ux - di[i]
        fs = uy - dj[i]
        if ss <= 0:
            dss = 0; ss0 = 0; ss1 = 0
        elif ss >= aa - 1:
            dss = 0; ss0 = aa - 1; ss1 = aa - 1
        else:
            ss = ss; dss = ss - floor(ss)
            ss0 = <int>(floor(ss)); ss1 = ss0 + 1
        if fs <= 0:
            dfs = 0; fs0 = 0; fs1 = 0
        elif fs >= bb - 1:
            dfs = 0; fs0 = bb - 1; fs1 = bb - 1
        else:
            fs = fs; dfs = fs - floor(fs)
            fs0 = <int>(floor(fs)); fs1 = fs0 + 1
        I0_bi = (1 - dss) * (1 - dfs) * I0[ss0, fs0] + \
                (1 - dss) * dfs * I0[ss0, fs1] + \
                dss * (1 - dfs) * I0[ss1, fs0] + \
                dss * dfs * I0[ss1, fs1]
        SS_res += (I[i] - I0_bi)**2
        SS_tot += (I[i] - 1)**2
    m_ptr[0] = SS_res / SS_tot
    if m_ptr[1] >= 0:
        m_ptr[1] = 4 * I[a] * (SS_res / SS_tot**2 + SS_res**2 / SS_tot**3)

cdef void krig_data_c(float_t[::1] I, float_t[:, :, ::1] I_n, float_t[:, ::1] W, float_t[:, :, ::1] u,
                      int j, int k, float_t ls) nogil:
    cdef:
        int a = I_n.shape[0], b = I_n.shape[1], c = I_n.shape[2], i, jj, kk
        int djk = <int>(ceil(2 * ls))
        int jj0 = j - djk if j - djk > 0 else 0
        int jj1 = j + djk if j + djk < b else b
        int kk0 = k - djk if k - djk > 0 else 0
        int kk1 = k + djk if k + djk < c else c
        float_t w0 = 0, rss = 0, r
    for i in range(a):
        I[i] = 0
    for jj in range(jj0, jj1):
        for kk in range(kk0, kk1):
            r = rbf((u[0, jj, kk] - u[0, j, k])**2 + (u[1, jj, kk] - u[1, j, k])**2, ls)
            w0 += r * W[jj, kk]**2
            rss += W[jj, kk]**3 * r**2
            for i in range(a):
                I[i] += I_n[i, jj, kk] * W[jj, kk] * r
    for i in range(a):
        I[i] /= w0
    I[a] = rss / w0**2

cdef void subpixel_ref_2d(float_t[::1] I, float_t[:, ::1] I0, float_t[::1] u,
                          float_t[::1] di, float_t[::1] dj, float_t l1) nogil:
    cdef:
        float_t dss = 0, dfs = 0, det, mu, dd
        float_t f22, f11, f00, f21, f01, f12, f10
        float_t mv_ptr[2]
    mse_bi(mv_ptr, I, I0, di, dj, u[0], u[1])
    f11 = mv_ptr[0]
    mu = MU_C * mv_ptr[1]**0.25 / sqrt(l1)
    mu = mu if mu > 2 else 2
    mv_ptr[1] = NO_VAR

    mse_bi(mv_ptr, I, I0, di, dj, u[0] - mu / 2, u[1] - mu / 2)
    f00 = mv_ptr[0]
    mse_bi(mv_ptr, I, I0, di, dj, u[0] - mu / 2, u[1])
    f01 = mv_ptr[0]
    mse_bi(mv_ptr, I, I0, di, dj, u[0], u[1] - mu / 2)
    f10 = mv_ptr[0]
    mse_bi(mv_ptr, I, I0, di, dj, u[0], u[1] + mu / 2)
    f12 = mv_ptr[0]
    mse_bi(mv_ptr, I, I0, di, dj, u[0] + mu / 2, u[1])
    f21 = mv_ptr[0]
    mse_bi(mv_ptr, I, I0, di, dj, u[0] + mu / 2, u[1] + mu / 2)
    f22 = mv_ptr[0]

    det = 4 * (f21 + f01 - 2 * f11) * (f12 + f10 - 2 * f11) - \
          (f22 + f00 + 2 * f11 - f01 - f21 - f10 - f12)**2
    if det != 0:
        dss = ((f22 + f00 + 2 * f11 - f01 - f21 - f10 - f12) * (f12 - f10) - \
               2 * (f12 + f10 - 2 * f11) * (f21 - f01)) / det * mu / 2
        dfs = ((f22 + f00 + 2 * f11 - f01 - f21 - f10 - f12) * (f21 - f01) - \
               2 * (f21 + f01 - 2 * f11) * (f12 - f10)) / det * mu / 2
        dd = sqrt(dfs**2 + dss**2)
        if dd > 1:
            dss /= dd; dfs /= dd
    
    u[0] += dss; u[1] += dfs

cdef void subpixel_ref_1d(float_t[::1] I, float_t[:, ::1] I0, float_t[::1] u,
                          float_t[::1] di, float_t[::1] dj, float_t l1) nogil:
    cdef:
        float_t dfs = 0, det, mu, dd
        float_t f11, f12, f10
        float_t mv_ptr[2]
    mse_bi(mv_ptr, I, I0, di, dj, u[0], u[1])
    f11 = mv_ptr[0]
    mu = MU_C * mv_ptr[1]**0.25 / sqrt(l1)
    mu = mu if mu > 2 else 2
    mv_ptr[1] = NO_VAR

    mse_bi(mv_ptr, I, I0, di, dj, u[0], u[1] - mu / 2)
    f10 = mv_ptr[0]
    mse_bi(mv_ptr, I, I0, di, dj, u[0], u[1] + mu / 2)
    f12 = mv_ptr[0]

    det = 4 * (f12 + f10 - 2 * f11)
    if det != 0:
        dfs = (f10 - f12) / det * mu
        dd = sqrt(dfs**2)
        if dd > 1:
            dfs /= dd

    u[1] += dfs

cdef void mse_min_c(float_t[::1] I, float_t[:, ::1] I0, float_t[::1] u,
                    float_t[::1] di, float_t[::1] dj, int* bnds) nogil:
    cdef:
        int sslb = -bnds[0] if bnds[0] < u[0] - bnds[2] else <int>(bnds[2] - u[0])
        int ssub = bnds[0] if bnds[0] < bnds[3] - u[0] else <int>(bnds[3] - u[0])
        int fslb = -bnds[1] if bnds[1] < u[1] - bnds[4] else <int>(bnds[4] - u[1])
        int fsub = bnds[1] if bnds[1] < bnds[5] - u[1] else <int>(bnds[5] - u[1])
        int ss_min = sslb, fs_min = fslb, ss_max = sslb, fs_max = fslb, ss, fs
        float_t mse_min = FLOAT_MAX, mse_max = -FLOAT_MAX, l1
        float_t mv_ptr[2]
    mv_ptr[1] = NO_VAR
    for ss in range(sslb, ssub):
        for fs in range(fslb, fsub):
            mse_bi(mv_ptr, I, I0, di, dj, u[0] + ss, u[1] + fs)
            if mv_ptr[0] < mse_min:
                mse_min = mv_ptr[0]; ss_min = ss; fs_min = fs
            if mv_ptr[0] > mse_max:
                mse_max = mv_ptr[0]; ss_max = ss; fs_max = fs
    u[0] += ss_min; u[1] += fs_min
    l1 = 2 * (mse_max - mse_min) / ((ss_max - ss_min)**2 + (fs_max - fs_min)**2)
    if ssub - sslb > 1:
        subpixel_ref_2d(I, I0, u, di, dj, l1)
    else:
        subpixel_ref_1d(I, I0, u, di, dj, l1)

def update_pixel_map_gs(float_t[:, :, ::1] I_n, float_t[:, ::1] W, float_t[:, ::1] I0,
                        float_t[:, :, ::1] u0, float_t[::1] di, float_t[::1] dj,
                        int sw_ss, int sw_fs, float_t ls):
    r"""Update the pixel mapping by minimizing mean-squared-error
    (MSE). Perform a grid search within the search window of `sw_ss`,
    `sw_fs` size along the slow and fast axes accordingly in order to
    minimize the MSE.

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
        Sample's translations along the slow detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    sw_ss : int
        Search window size in pixels along the slow detector
        axis.
    sw_fs : int
        Search window size in pixels along the fast detector
        axis.
    ls : float
        Reference image length scale in pixels.

    Returns
    -------
    u : numpy.ndarray
        Updated pixel mapping array.

    Notes
    -----
    The following error metric is being minimized:

    .. math::

        MSE[i, j] = \frac{\sum_n \left( I_g[n]
        - I_{ref}[ii_n, jj_n] \right)^2}{\sum_n \left(
        I_g[n] - 1 \right)^2}
    
    Where :math:`I_g[n]` is a kriged intensity profile of the
    particular detector coordinate :math:`I_n[n, i, j]`. Intensity
    profile :math:`I_n[n, i, j]` is kriged with gaussian radial
    basis function :math:`\phi`:

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
    dtype = np.float64 if float_t is np.float64_t else np.float32
    cdef:
        int a = I_n.shape[0], b = I_n.shape[1], c = I_n.shape[2]
        int aa = I0.shape[0], bb = I0.shape[1], j, k, t
        int max_threads = openmp.omp_get_max_threads()
        float_t[::1, :, :] u = np.empty((2, b, c), dtype=dtype, order='F')
        float_t[:, ::1] I = np.empty((max_threads, a + 1), dtype=dtype)
        int bnds[6] # sw_ss, sw_fs, di0, di1, dj0, dj1
    bnds[0] = sw_ss if sw_ss >= 1 else 1; bnds[1] = sw_fs if sw_fs >= 1 else 1
    bnds[2] = <int>(min_float(&di[0], a)); bnds[3] = <int>(max_float(&di[0], a)) + aa
    bnds[4] = <int>(min_float(&dj[0], a)); bnds[5] = <int>(max_float(&dj[0], a)) + bb
    for k in prange(c, schedule='guided', nogil=True):
        t = openmp.omp_get_thread_num()
        for j in range(b):
            krig_data_c(I[t], I_n, W, u0, j, k, ls)
            u[:, j, k] = u0[:, j, k]
            mse_min_c(I[t], I0, u[:, j, k], di, dj, bnds)
    return np.asarray(u, order='C')

cdef void init_newton_c(float_t[::1] sptr, float_t[::1] I, float_t[:, ::1] I0,
                        float_t[::1] u, float_t[::1] di, float_t[::1] dj, int* bnds) nogil:
    cdef:
        int sslb = -bnds[0] if bnds[0] < u[0] - bnds[2] else <int>(bnds[2] - u[0])
        int ssub = bnds[0] if bnds[0] < bnds[3] - u[0] else <int>(bnds[3] - u[0])
        int fslb = -bnds[1] if bnds[1] < u[1] - bnds[4] else <int>(bnds[4] - u[1])
        int fsub = bnds[1] if bnds[1] < bnds[5] - u[1] else <int>(bnds[5] - u[1])
        int ss, fs, ss_max = sslb, fs_max = fslb
        float_t mse_min = FLOAT_MAX, mse_max = -FLOAT_MAX, l1 = 0, d0, l, dist
        float_t mptr[2]
    mptr[1] = NO_VAR; sptr[2] = 0
    for ss in range(sslb, ssub):
        for fs in range(fslb, fsub):
            mse_bi(mptr, I, I0, di, dj, u[0] + ss, u[1] + fs)
            if mptr[0] < mse_min:
                mse_min = mptr[0]; sptr[0] = ss; sptr[1] = fs
            if mptr[0] > mse_max:
                mse_max = mptr[0]; ss_max = ss; fs_max = fs
    d0 = (ss_max - sptr[0])**2 + (fs_max - sptr[1])**2
    l1 = 2 * (mse_max - mse_min) / d0
    for ss in range(sslb, ssub):
        for fs in range(fslb, fsub):
            dist = (ss - sptr[0])**2 + (fs - sptr[1])**2
            if dist > d0 / 4 and dist < d0:
                mse_bi(mptr, I, I0, di, dj, u[0] + ss, u[1] + fs)
                l = 2 * (mptr[0] - mse_min) / dist
                if l > l1:
                    l1 = l
    sptr[2] = l1

cdef void newton_1d_c(float_t[::1] sptr, float_t[::1] I, float_t[:, ::1] I0, float_t[::1] u,
                      float_t[::1] di, float_t[::1] dj, int* bnds, int max_iter, float_t x_tol) nogil:
    cdef:
        int fslb = -bnds[1] if bnds[1] < u[1] - bnds[4] else <int>(bnds[4] - u[1]), k
        int fsub = bnds[1] if bnds[1] < bnds[5] - u[1] else <int>(bnds[5] - u[1])
        float_t ss, fs, mu, dfs
        float_t mptr0[2]
        float_t mptr1[2]
        float_t mptr2[2]
    if sptr[2] == 0:
        init_newton_c(sptr, I, I0, u, di, dj, &bnds[0])
    ss = sptr[0]; fs = sptr[1]; mptr1[1] = NO_VAR; mptr2[1] = NO_VAR
    for k in range(max_iter):
        mse_bi(mptr0, I, I0, di, dj, u[0] + ss, u[1] + fs)
        mu = MU_C * mptr0[1]**0.25 / sqrt(sptr[2])
        mse_bi(mptr1, I, I0, di, dj, u[0] + ss, u[1] + fs - mu / 2)
        mse_bi(mptr2, I, I0, di, dj, u[0] + ss, u[1] + fs + mu / 2)
        dfs = -(mptr2[0] - mptr1[0]) / mu / sptr[2]
        fs += dfs
        if dfs < x_tol and dfs > -x_tol:
            u[1] += fs; sptr[1] = fs
            break
        if fs >= fsub or fs < fslb:
            u[1] += sptr[1]
            break
    else:
        u[1] += fs; sptr[1] = fs

def update_pixel_map_nm(float_t[:, :, ::1] I_n, float_t[:, ::1] W, float_t[:, ::1] I0, float_t[:, :, ::1] u0,
                        float_t[::1] di, float_t[::1] dj, int sw_fs, float_t ls,
                        int max_iter=500, float_t x_tol=1e-12):
    r"""Update the pixel mapping by minimizing mean-squared-error
    (MSE). Perform an iterative Newton's method within the search window
    of `sw_ss`, `sw_fs` size along the slow and fast axes accordingly
    in order to minimize the MSE. only works with 1D scans.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    I0 : numpy.ndarray
        Reference image of the sample.
    u : numpy.ndarray
        Initial pixel mapping.
    di : numpy.ndarray
        Sample's translations along the slow detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    sw_ss : int
        Search window size in pixels along the slow detector
        axis.
    sw_fs : int
        Search window size in pixels along the fast detector
        axis.
    ls : float
        Reference image length scale in pixels.
    max_iter : int, optional
        Maximum number of iterations.
    x_tol : float, optional
        Tolerance for termination by the change of `u`.

    Returns
    -------
    u : numpy.ndarray
        Updated pixel mapping array.

    Notes
    -----
    :func:`update_pixel_map_nm` employs finite difference of MSE
    instead of conventional numerical derivative. Finite difference
    yields smaller variance in the case of noise present in the data
    [MW]_:

    .. math::
        \varepsilon (h) = \frac{f(x + h) - f(x)}{h}

    Where variance is minimized if :math:`h = h_M`:

    .. math::
        h_M = 8^{0.25} \sqrt{\frac{\mathrm{Var}[f]}
        {\left| \max{f^{\prime\prime}} \right|}}

    See Also
    --------
    update_pixel_map_gs : Description of error metric which
        is being minimized.

    References
    ----------
    .. [MW] Jorge J. Moré, and Stefan M. Wild, "Estimating Derivatives
            of Noisy Simulations", ACM Trans. Math. Softw., Vol. 38,
            Number 3, April 2012.
    """
    dtype = np.float64 if float_t is np.float64_t else np.float32
    cdef:
        int a = I_n.shape[0], b = I_n.shape[1], c = I_n.shape[2]
        int aa = I0.shape[0], bb = I0.shape[1], j, k, t
        int max_threads = openmp.omp_get_max_threads()
        float_t[::1, :, :] u = np.empty((2, b, c), dtype=dtype, order='F')
        float_t[:, ::1] I = np.empty((max_threads, a + 1), dtype=dtype)
        float_t[:, ::1] sptr = np.zeros((max_threads, 3), dtype=dtype) # ss, fs, l1
        int bnds[6] # sw_ss, sw_fs, di0, di1, dj0, dj1
    bnds[0] = 1; bnds[1] = sw_fs if sw_fs >= 1 else 1
    bnds[2] = <int>(min_float(&di[0], a)); bnds[3] = <int>(max_float(&di[0], a)) + aa
    bnds[4] = <int>(min_float(&dj[0], a)); bnds[5] = <int>(max_float(&dj[0], a)) + bb
    for k in prange(c, schedule='static', nogil=True):
        t = openmp.omp_get_thread_num()
        for j in range(b):
            krig_data_c(I[t], I_n, W, u0, j, k, ls)
            u[:, j, k] = u0[:, j, k]
            newton_1d_c(sptr[t], I[t], I0, u[:, j, k], di, dj, bnds, max_iter, x_tol)
    return np.asarray(u)

def total_mse(float_t[:, :, ::1] I_n, float_t[:, ::1] W, float_t[:, ::1] I0,
              float_t[:, :, ::1] u, float_t[::1] di, float_t[::1] dj, float_t ls):
    """Return the average mean-squared-error (MSE) value per pixel.

    Parameters
    ----------
    I_n : numpy.ndarray
        Measured intensity frames.
    W : numpy.ndarray
        Measured frames' whitefield.
    I0 : numpy.ndarray
        Reference image of the sample.
    u : numpy.ndarray
        Initial pixel mapping.
    di : numpy.ndarray
        Sample's translations along the slow detector axis
        in pixels.
    dj : numpy.ndarray
        Sample's translations along the fast detector axis
        in pixels.
    ls : float
        Reference image length scale in pixels.

    Returns
    -------
    mse : float
        Average MSE per pixel.

    See Also
    --------
    update_pixel_map_gs : Description of error metric which
        is being minimized.
    """
    dtype = np.float64 if float_t is np.float64_t else np.float32
    cdef:
        int a = I_n.shape[0], b = I_n.shape[1], c = I_n.shape[2]
        int aa = I0.shape[0], bb = I0.shape[1], j, k, t
        int max_threads = openmp.omp_get_max_threads()
        float_t err = 0
        float_t[:, ::1] mptr = NO_VAR * np.ones((max_threads, 2), dtype=dtype)
        float_t[:, ::1] I = np.empty((max_threads, a + 1), dtype=dtype)
    for k in prange(c, schedule='static', nogil=True):
        t = openmp.omp_get_thread_num()
        for j in range(b):
            krig_data_c(I[t], I_n, W, u, j, k, ls)
            mse_bi(&mptr[t, 0], I[t], I0, di, dj, u[0, j, k], u[1, j, k])
            err += mptr[t, 0]
    return err / b / c

def ct_integrate(float_t[:, ::1] sx_arr, float_t[:, ::1] sy_arr):
    """Perform the Fourier Transform wavefront reconstruction [FTI]_
    with antisymmetric derivative integration [ASDI]_.

    Parameters
    ----------
    sx_arr : numpy.ndarray
        Array of gradient values along the fast axis.

    sy_arr : numpy.ndarray
        Array of gradient values along the slow axis.

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
    dtype = np.float64 if float_t is np.float64_t else np.float32
    cdef:
        int a = sx_arr.shape[0], b = sx_arr.shape[1], i, j, ii, jj
        float_t xf, yf
        np.ndarray[np.complex128_t, ndim=2] s_asdi = empty_aligned((2 * a, 2 * b), dtype='complex128')
        np.ndarray[np.complex128_t, ndim=2] sf_asdi = empty_aligned((2 * a, 2 * b), dtype='complex128')
        np.ndarray[np.complex128_t, ndim=2] w_asdi = empty_aligned((2 * a, 2 * b), dtype='complex128')
    fft_obj = FFTW(s_asdi, sf_asdi, axes=(0, 1))
    ifft_obj = FFTW(sf_asdi, w_asdi, axes=(0, 1), direction='FFTW_BACKWARD')
    for i in range(a):
        for j in range(b):
            s_asdi[i, j] = -sx_arr[a - i - 1, b - j - 1]
    for i in range(a):
        for j in range(b):
            s_asdi[i + a, j] = sx_arr[i, b - j - 1]
    for i in range(a):
        for j in range(b):
            s_asdi[i, j + b] = -sx_arr[a - i - 1, j]
    for i in range(a):
        for j in range(b):
            s_asdi[i + a, j + b] = sx_arr[i, j]
    cdef np.ndarray[np.complex128_t, ndim=2] sfx_asdi = fft_obj().copy()
    for i in range(a):
        for j in range(b):
            s_asdi[i, j] = -sy_arr[a - i - 1, b - j - 1]
    for i in range(a):
        for j in range(b):
            s_asdi[i + a, j] = -sy_arr[i, b - j - 1]
    for i in range(a):
        for j in range(b):
            s_asdi[i, j + b] = sy_arr[a - i - 1, j]
    for i in range(a):
        for j in range(b):
            s_asdi[i + a, j + b] = sy_arr[i, j]
    cdef np.ndarray[np.complex128_t, ndim=2] sfy_asdi = fft_obj().copy()
    for i in range(2 * a):
        xf = <float_t>(i) / 2 / a - i // a
        for j in range(2 * b):
            yf = <float_t>(j) / 2 / b - j // b
            sf_asdi[i, j] = (xf * sfx_asdi[i, j] + yf * sfy_asdi[i, j]) / (2j * pi * (xf**2 + yf**2))
    sf_asdi[0, 0] = 0
    ifft_obj()
    return np.asarray(w_asdi.real[a:, b:], dtype=dtype)