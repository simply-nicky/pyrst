"""Robust Speckle Tracking data processing algorithm.
:class:`pyrost.STData` contains all the necessary data for the Speckle
Tracking algorithm, and handy data processing tools to work
with the data. :class:`pyrost.SpeckleTracking` performs the main
Robust Speckle Tracking algorithm and yields reference image
and pixel mapping. :class:`pyrost.AberrationsFit` fit the lens'
aberrations profile with the polynomial function using
nonlinear least-squares algorithm.

Examples
--------
Extract all the necessary data using a :func:`pyrost.cxi_loader` function.

>>> import pyrost as rst
>>> loader = rst.cxi_loader()
>>> rst_data = loader.load('results/test/data.cxi')

Perform the Robust Speckle Tracking using a :class:`pyrost.SpeckleTracking` object.

>>> rst_obj = rst_data.get_st()
>>> rst_res, errors = rst_obj.iter_update(sw_x=150, h0=10.,
...                                       verbose=True, n_iter=10)
Iteration No. 0: Total MSE = 0.150
Iteration No. 1: Total MSE = 0.077
Iteration No. 2: Total MSE = 0.052
Iteration No. 3: Total MSE = 0.050

Extract lens' aberrations wavefront and fit it with a polynomial.

>>> rst_data.update_phase(rst_res)
>>> fit_res = rst_data.fit_phase()
>>> fit_res['ph_fit']
array([-5.19025587e+07, -8.63773622e+05,  3.42849675e+03,  2.98523995e+01,
        1.19773905e-02])
"""
from __future__ import annotations
from typing import Any, Dict, Iterable, List, Optional, Tuple, Union
from weakref import ref
from multiprocessing import cpu_count
from tqdm.auto import tqdm
import h5py
import numpy as np
from .aberrations_fit import AberrationsFit
from .data_container import DataContainer, dict_to_object
from .cxi_protocol import CXIProtocol, CXI_PROTOCOL
from .rst_update import SpeckleTracking
from .bin import median, median_filter, fft_convolve, ct_integrate

class CXILoader(CXIProtocol):
    """CXI file loader class. Loads data from a
    CXI file and returns a :class:`STData` container or a
    :class:`dict` with the data. Search data in the paths
    provided by `protocol` and `load_paths`.

    Parameters
    ----------
    protocol : CXIProtocol, optional
        Protocol object. The default protocol is used if None.
        Default protocol is used if not provided.
    load_paths : dict, optional
        Extra paths to the data attributes in a CXI file,
        which override `protocol`. Accepts only the attributes
        enlisted in `protocol`. Default paths are used if
        not provided.
    policy : dict, optional
        A dictionary with loading policy. Contains all the
        attributes that are available in `protocol` with their
        corresponding flags. If a flag is True, the attribute
        will be loaded from a file. Default policy is used if
        not provided.

    Attributes
    ----------
    config : dict
        Protocol configuration.
    datatypes : dict
        Dictionary with attributes' datatypes. 'float', 'int', or 'bool'
        are allowed.
    default_paths : dict
        Dictionary with attributes' CXI default file paths.
    is_data : dict
        Dictionary with the flags if the attribute is of data type.
        Data type is 2- or 3-dimensional and has the same data shape
        as `data`.
    load_paths : dict
        Extra set of paths to the attributes enlisted in `datatypes`.
    policy: dict
        Loading policy.

    See Also
    --------
    cxi_protocol : Full list of data attributes and configuration
        parameters.
    STData : Data container with all the data  necessary for
        Speckle Tracking.
    """
    attr_dict = {'config': ('float_precision', ), 'datatypes': ('ALL', ),
                 'default_paths': ('ALL', ), 'load_paths': ('ALL',),
                 'is_data': ('ALL', ), 'policy': ('ALL', )}
    fmt_dict = {'config': 'str','datatypes': 'str', 'default_paths': 'str',
                'load_paths': 'str', 'is_data': 'str', 'policy': 'str'}

    def __init__(self, protocol: CXIProtocol, load_paths: Dict[str, List[str]],
                 policy: Dict[str, Union[str, bool]]) -> None:
        load_paths = {attr: paths for attr, paths in load_paths.items()
                      if attr in protocol}
        policy = {attr: flag for attr, flag in policy.items() if attr in protocol}
        super(CXIProtocol, self).__init__(config=protocol.config, datatypes=protocol.datatypes,
                                          default_paths=protocol.default_paths,
                                          is_data=protocol.is_data, load_paths=load_paths,
                                          policy=policy)

        if self.config['float_precision'] == 'float32':
            self.known_types['float'] = np.float32
        elif self.config['float_precision'] == 'float64':
            self.known_types['float'] = np.float64
        else:
            raise ValueError('Invalid float precision: {:s}'.format(self.config['float_precision']))

    @staticmethod
    def str_to_list(strings: Union[str, List[str]]) -> List[str]:
        """Convert `strings` to a list of strings.

        Parameters
        ----------
        strings : str or list
            String or a list of strings

        Returns
        -------
        list
            List of strings.
        """
        if isinstance(strings, (str, list)):
            if isinstance(strings, str):
                return [strings,]
            return strings

        raise ValueError('strings must be a string or a list of strings')

    @classmethod
    def import_default(cls, protocol: Optional[CXIProtocol]=None,
                       load_paths: Optional[Dict[str, List[str]]]=None,
                       policy: Optional[Dict[str, Union[str, bool]]]=None) -> CXILoader:
        """Return the default :class:`CXILoader` object. Extra arguments
        override the default values if provided.

        Parameters
        ----------
        protocol : CXIProtocol, optional
            Protocol object.
        load_paths : dict, optional
            Extra paths to the data attributes in a CXI file,
            which override `protocol`. Accepts only the attributes
            enlisted in `protocol`.
        policy : dict, optional
            A dictionary with loading policy. Contains all the
            attributes that are available in `protocol` and the
            corresponding flags. If a flag is True, the attribute
            will be loaded from a file.

        Returns
        -------
        CXILoader
            A :class:`CXILoader` object with the default parameters.

        See Also
        --------
        cxi_protocol : more details about the default CXI loader.
        """
        return cls.import_ini(CXI_PROTOCOL, protocol, load_paths, policy)

    @classmethod
    def import_ini(cls, ini_file: str, protocol: Optional[CXIProtocol]=None,
                   load_paths: Optional[Dict[str, List[str]]]=None,
                   policy: Optional[Dict[str, Union[str, bool]]]=None) -> CXILoader:
        """Initialize a :class:`CXILoader` object class with an
        ini file.

        Parameters
        ----------
        ini_file : str
            Path to the ini file. Loads the default CXI loader if None.
        protocol : CXIProtocol, optional
            Protocol object. Initialized with `ini_file` if None.
        load_paths : dict, optional
            Extra paths to the data attributes in a CXI file,
            which override `protocol`. Accepts only the attributes
            enlisted in `protocol`. Initialized with `ini_file`
            if None.
        policy : dict, optional
            A dictionary with loading policy. Contains all the
            attributes that are available in `protocol` and the
            corresponding flags. If a flag is True, the attribute
            will be loaded from a file. Initialized with `ini_file`
            if None.

        Returns
        -------
        CXILoader
            A :class:`CXILoader` object with all the attributes imported
            from the ini file.

        See Also
        --------
        cxi_protocol : more details about the default CXI loader.
        """
        if protocol is None:
            protocol = CXIProtocol.import_ini(ini_file)
        kwargs = cls._import_ini(ini_file)
        if not load_paths is None:
            kwargs['load_paths'].update(**load_paths)
        if not policy is None:
            kwargs['policy'].update(**policy)
        return cls(protocol=protocol, load_paths=kwargs['load_paths'],
                   policy=kwargs['policy'])

    def get_load_paths(self, attr: str, value: Optional[Union[str, List[str]]]=None) -> List[str]:
        """Return the atrribute's path in the cxi file.
        Return `value` if `attr` is not found.

        Parameters
        ----------
        attr : str
            The attribute to look for.
        value : str, optional
            value which is returned if the `attr` is not found.

        Returns
        -------
        list
            Set of attribute's paths.
        """
        paths = self.str_to_list(super(CXILoader, self).get_default_path(attr, value))
        if attr in self.load_paths:
            paths.extend(self.load_paths[attr])
        return paths

    def get_policy(self, attr: str, value: bool=False) -> bool:
        """Return the atrribute's loding policy.

        Parameters
        ----------
        attr : str
            The attribute to look for.
        value : str, optional
            value which is returned if the `attr` is not found.

        Returns
        -------
        bool
            Attributes' loding policy.
        """
        policy = self.policy.get(attr, value)
        if isinstance(policy, str):
            return policy in ['True', 'true', '1', 'y', 'yes']
        else:
            return bool(policy)

    def get_protocol(self) -> CXIProtocol:
        """Return a CXI protocol from the loader.

        Returns
        -------
        CXIProtocol
            CXI protocol.
        """
        return CXIProtocol(datatypes=self.datatypes,
                           default_paths=self.default_paths,
                           is_data=self.is_data,
                           float_precision=self.config['float_precision'])

    def find_path(self, attr: str, cxi_file: h5py.File) -> str:
        """Find attribute's path in a CXI file `cxi_file`.

        Parameters
        ----------
        attr : str
            Data attribute.
        cxi_file : h5py.File
            :class:`h5py.File` object of the CXI file.

        Returns
        -------
        str
            Atrribute's path in the CXI file,
            returns an empty string if the attribute is not found.
        """
        paths = self.get_load_paths(attr)
        for path in paths:
            if path in cxi_file:
                return path
        return str()

    def load_attributes(self, master_file: str) -> Dict[str, Any]:
        """Return attributes' values from a CXI file at
        the given `master_file`.

        Parameters
        ----------
        master_file : str
            Path to the master CXI file.

        Returns
        -------
        attr_dict : dict
            Dictionary with the attributes retrieved from
            the CXI file.
        """
        attr_dict = {}
        with h5py.File(master_file, 'r') as cxi_file:
            for attr in self:
                cxi_path = self.find_path(attr, cxi_file)
                if not self.get_is_data(attr) and self.get_policy(attr, False) and cxi_path:
                    attr_dict[attr] = self.read_cxi(attr, cxi_file, cxi_path)
        return attr_dict

    def read_indices(self, attr: str, data_files: Union[str, List[str]]) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Retrieve the indices of the datasets from the CXI files for the
        given attribute `attr`.

        Parameters
        ----------
        attr : str
            The attribute to read.
        data_files : str or list of str
            Paths to the data CXI files.

        Returns
        -------
        paths : np.ndarray or None.
            List of the file paths. None if no data is found.
        cxi_paths : np.ndarray or None
            List of the paths inside the files. None if no data
            is found.
        indices : np.ndarray or None
            List of the frame indices. None if no data is found.
        """
        data_files = self.str_to_list(data_files)

        paths, cxi_paths, indices = [], [], []
        for path in data_files:
            with h5py.File(path, 'r') as cxi_file:
                shapes = self.read_shape(cxi_file, self.find_path(attr, cxi_file))
            if shapes:
                for cxi_path, dset_shape in shapes:
                    if len(dset_shape) == 3:
                        paths.append(np.repeat(path, dset_shape[0]))
                        cxi_paths.append(np.repeat(cxi_path, dset_shape[0]))
                        indices.append(np.arange(dset_shape[0]))
                    elif len(dset_shape) == 2:
                        paths.append(np.atleast_1d(path))
                        cxi_paths.append(np.atleast_1d(cxi_path))
                        indices.append(np.atleast_1d(slice(None)))
                    else:
                        raise ValueError('Dataset must be 2- or 3-dimensional')

        if len(paths) == 0:
            return np.array([]), np.array([]), np.array([])
        elif len(paths) == 1:
            return paths[0], cxi_paths[0], indices[0]
        else:
            return (np.concatenate(paths), np.concatenate(cxi_paths),
                    np.concatenate(indices))

    def load_data(self, attr: str, paths: np.ndarray, cxi_paths: np.ndarray, indices: np.ndarray,
                  verbose: bool=True) -> np.ndarray:
        """Retrieve the data for the given attribute `attr` from the
        CXI files. Uses the result from :func:`CXILoader.read_indices`
        method.

        Parameters
        ----------
        attr : str
            The attribute to read.
        paths : np.ndarray
            List of the file paths.
        cxi_paths : np.ndarray
            List of the paths inside the files.
        indices : np.ndarray
            List of the frame indices.
        verbose : bool, optional
            Print the progress bar if True.

        Returns
        -------
        data : np.ndarray
            Data array retrieved from the CXI files.
        """
        data = []
        for path, cxi_path, index in tqdm(zip(paths, cxi_paths, indices),
                                          disable=not verbose, total=paths.size,
                                          desc=f'Loading {attr:s}'):
            with h5py.File(path, 'r') as cxi_file:
                data.append(cxi_file[cxi_path][index])

        if len(data) == 1:
            data = data[0]
        else:
            data = np.stack(data, axis=0)
        return np.asarray(data, dtype=self.get_dtype(attr))

    def load_to_dict(self, data_files: Union[str, List[str]], master_file: Optional[str]=None,
                     frame_indices: Optional[Iterable[int]]=None, **attributes: Any) -> Dict[str, Any]:
        """Load data from the CXI files and return a :class:`dict` with
        all the data fetched from the `data_files` and `master_file`.

        Parameters
        ----------
        data_files : str or list of str
            Paths to the data CXI files.
        master_file : str, optional
            Path to the master CXI file. First file in `data_files`
            if not provided.
        frame_indices : sequence of int, optional
            Array of frame indices to load. Loads all the frames by
            default.
        **attributes : dict, optional
            Dictionary of attribute values, that override the loaded
            values.

        Returns
        -------
        dict
            Dictionary with all the data fetched from the CXI files.
        """
        if master_file is None:
            if isinstance(data_files, str):
                master_file = data_files
            elif isinstance(data_files, list):
                master_file = data_files[0]
            else:
                raise ValueError('data_files must be a string or a list of strings')

        data_dict = self.load_attributes(master_file)

        if frame_indices is None:
            n_frames = 0
            for attr in self:
                if self.get_is_data(attr) and self.get_policy(attr):
                    n_frames = max(self.read_indices(attr, data_files)[0].size, n_frames)
            frame_indices = np.arange(n_frames)
        else:
            frame_indices = np.asarray(frame_indices)

        if frame_indices.size:
            for attr in self:
                if self.get_is_data(attr) and self.get_policy(attr):
                    paths, cxi_paths, indices = self.read_indices(attr, data_files)
                    if paths.size > 0:
                        good_frames = frame_indices[frame_indices < paths.size]
                        data_dict[attr] = self.load_data(attr, paths[good_frames],
                                                        cxi_paths[good_frames],
                                                        indices[good_frames])

        for attr, val in attributes.items():
            if attr in self and val is not None:
                if isinstance(val, dict):
                    data_dict[attr] = {dkey: self.get_dtype(attr)(dval)
                                       for dkey, dval in val.items()}
                else:
                    data_dict[attr] = np.asarray(val, dtype=self.get_dtype(attr))
                    if data_dict[attr].size == 1:
                        data_dict[attr] = data_dict[attr].item()

        return data_dict

    def load(self, data_files: str, master_file: Optional[str]=None,
             frame_indices: Optional[Iterable[str]]=None, **attributes: Any) -> STData:
        """Load data from the CXI files and return a :class:`STData` container
        with all the data fetched from the `data_files` and `master_file`.

        Parameters
        ----------
        data_files : str or list of str
            Paths to the data CXI files.
        master_file : str, optional
            Path to the master CXI file. First file in `data_files`
            if not provided.
        frame_indices : sequence of int, optional
            Array of frame indices to load. Loads all the frames by
            default.
        **attributes : dict
            Dictionary of attribute values,
            which will be parsed to the `STData` object instead.

        Returns
        -------
        STData
            Data container object with all the necessary data
            for the Speckle Tracking algorithm.
        """
        return STData(self.get_protocol(), **self.load_to_dict(data_files, master_file,
                                                               frame_indices, **attributes))

class STData(DataContainer):
    """Speckle Tracking algorithm data container class.
    Contains all the necessary data for the Robust Speckle
    Tracking algorithm (specified in `attr_set` and `init_set`),
    the list of all the :class:`SpeckleTracking` objects derived
    from it, and two :class:`AberrationsFit` objects to fit the phase
    along the horizontal and vertical detector axes.

    Parameters
    ----------
    protocol : CXIProtocol
        CXI :class:`CXIProtocol` object.
    num_threads : int, optional
        Specify number of threads that are used in all the calculations.

    **kwargs : dict
        Dictionary of the attributes' data specified in `attr_set`
        and `init_set`.

    Attributes
    ----------
    attr_set : set
        Set of attributes in the container which are necessary
        to initialize in the constructor.
    init_set : set
        Set of optional data attributes.

    Raises
    ------
    ValueError
        If an attribute specified in `attr_set` has not been provided.

    Notes
    -----
    Necessary attributes:

    * basis_vectors : Detector basis vectors
    * data : Measured intensity frames.
    * distance : Sample-to-detector distance [m].
    * translations : Sample's translations [m].
    * wavelength : Incoming beam's wavelength [m].
    * x_pixel_size : Pixel's size along the horizontal detector axis [m].
    * y_pixel_size : Pixel's size along the vertical detector axis [m].

    Optional attributes:

    * defocus_y : Defocus distance for the vertical detector axis [m].
    * defocus_x : Defocus distance for the horizontal detector axis [m].
    * error_frame : MSE (mean-squared-error) of the reference image
      and pixel mapping fit per pixel.
    * good_frames : An array of good frames' indices.
    * mask : Bad pixels mask.
    * phase : Phase profile of lens' aberrations.
    * pixel_map : The pixel mapping between the data at the detector's
      plane and the reference image at the reference plane.
    * pixel_aberrations : Lens' aberrations along the horizontal and
      vertical axes in pixels.
    * pixel_translations : Sample's translations in the detector's
      plane in pixels.
    * reference_image : The unabberated reference image of the sample.
    * roi : Region of interest in the detector plane.
    * whitefield : Measured frames' whitefield.
    """
    attr_set = {'basis_vectors', 'data', 'distance', 'protocol', 'translations', 'wavelength',
                'x_pixel_size', 'y_pixel_size'}
    init_set = {'defocus_x', 'defocus_y', 'error_frame', 'flatfields', 'good_frames',
                'mask', 'num_threads', 'phase', 'pixel_aberrations', 'pixel_map',
                'pixel_translations', 'reference_image', 'roi', 'sigma', 'whitefield'}

    inits = {'num_threads' : lambda attrs: np.clip(1, 64, cpu_count()),
             'roi'         : lambda attrs: np.array([0, attrs['data'].shape[1], 0,
                                                     attrs['data'].shape[2]]),
             'good_frames' : lambda attrs: np.arange(attrs['data'].shape[0]),
             'mask'        : lambda attrs: np.ones(attrs['data'].shape, dtype=bool),
             'whitefield'  : lambda attrs: median(data=attrs['data'][attrs['good_frames']],
                                                  mask=attrs['mask'][attrs['good_frames']],
                                                  axis=0, num_threads=attrs['num_threads']),
             'pixel_map'   : lambda attrs: np.indices(attrs['whitefield'].shape, dtype=float),
             'sigma'       : lambda attrs: np.std(attrs['data'][:, attrs['roi'][0]:attrs['roi'][1],
                                                                attrs['roi'][2]:attrs['roi'][3]] * \
                                                  attrs['mask'][:, attrs['roi'][0]:attrs['roi'][1],
                                                                attrs['roi'][2]:attrs['roi'][3]]),
             'defocus_y'   : lambda attrs: attrs.get('defocus_x', None)}

    def __init__(self, protocol: CXIProtocol=CXIProtocol.import_default(),
                 **kwargs: Union[int, float, np.ndarray]) -> None:
        # Initialize protocol for the proper data type conversion in __setattr__
        self.protocol = protocol

        if kwargs.get('mask') is not None and kwargs['mask'].shape == kwargs['data'].shape[1:]:
            kwargs['mask'] = np.tile(kwargs['mask'][None, :], (kwargs['data'].shape[0], 1, 1))

        # Initialize attr_dict
        super(STData, self).__init__(protocol=protocol, **kwargs)

        # Initialize init_set attributes
        if self._isdefocus:
            if self.get('pixel_translations') is None:
                self.pixel_translations = self.generate_pixel_translations()

    @property
    def _isdefocus(self) -> bool:
        return self.defocus_x is not None

    @property
    def _isphase(self) -> bool:
        return not self.pixel_aberrations is None and not self.phase is None

    def __setattr__(self, attr: str, value: Any) -> None:
        if attr in self:
            dtype = self.protocol.get_dtype(attr)
            if isinstance(value, np.ndarray):
                value = np.asarray(value, dtype=dtype)
            super(STData, self).__setattr__(attr, value)
        else:
            super(STData, self).__setattr__(attr, value)

    def generate_pixel_translations(self) -> np.ndarray:
        if not self._isdefocus:
            raise ValueError("'defocus_x' is not defined inside the container.")

        pixel_translations = (self.translations[:, None] * self.basis_vectors).sum(axis=-1)
        mag = np.abs(self.distance / np.array([self.defocus_y, self.defocus_x]))
        pixel_translations *= mag / (self.basis_vectors**2).sum(axis=-1)
        pixel_translations -= pixel_translations[0]
        pixel_translations -= pixel_translations.mean(axis=0)
        return pixel_translations

    @dict_to_object
    def bin_data(self, bin_ratio: int=2) -> STData:
        """Return a new :class:`STData` object with the data binned by
        a factor `bin_ratio`.

        Parameters
        ----------
        bin_ratio : int, optional
            Binning ratio. The frame size will decrease by the factor of
            `bin_ratio`.

        Returns
        -------
        STData
            New :class:`STData` object with binned `data`.
        """
        data_dict = {'basis_vectors': bin_ratio * self.basis_vectors,
                     'roi': self.roi // bin_ratio + (self.roi % bin_ratio > 0),
                     'pixel_map': self.pixel_map / 2,
                     'x_pixel_size': bin_ratio * self.x_pixel_size,
                     'y_pixel_size': bin_ratio * self.y_pixel_size}
        if self._isdefocus:
            data_dict['pixel_translations'] = self.pixel_translations / bin_ratio

        for attr, val in self.items():
            if val is not None and self.protocol.get_is_data(attr):
                if attr in data_dict:
                    data_dict[attr] = data_dict[attr][..., ::bin_ratio, ::bin_ratio]
                else:
                    data_dict[attr] = val[..., ::bin_ratio, ::bin_ratio]
        return data_dict

    @dict_to_object
    def crop_data(self, roi: Iterable[int]) -> STData:
        """Return a new :class:`STData` object with the updated `roi`.

        Parameters
        ----------
        roi : iterable of ints
            Region of interest in the detector plane.

        Returns
        -------
        STData
            New :class:`STData` object with the updated `roi`.
        """
        return {'roi': np.asarray(roi, dtype=int), 'flatfields': None, 'sigma': None}

    @dict_to_object
    def integrate_data(self, axis: int=0) -> STData:
        """Return a new :class:`STData` object with the `data` summed
        over the `axis`.

        Parameters
        ----------
        axis : int, optional
            Axis along which a sum is performed.

        Returns
        -------
        STData
            New :class:`STData` object with the updated `data`,
            `whitefield`, `mask`, and `roi`.
        """
        roi = self.roi.copy()
        roi[2 * axis:2 * (axis + 1)] = np.arange(2)

        data = np.zeros(self.data.shape, self.data.dtype)
        data[self.good_frames, self.roi[0]:self.roi[1],
             self.roi[2]:self.roi[3]] = self.get('data') * self.get('mask')
        return {'data': np.sum(data, axis=axis + 1, keepdims=True),
                'flatfields': None, 'mask': None, 'pixel_map': None,
                'pixel_translations': None, 'roi': roi, 'sigma': None,
                'whitefield': None}

    @dict_to_object
    def mask_frames(self, good_frames: Optional[Iterable[int]]=None) -> STData:
        """Return a new :class:`STData` object with the updated
        good frames mask. Mask empty frames by default.

        Parameters
        ----------
        good_frames : iterable, optional
            List of good frames' indices. Keeps non-empty frames
            if not provided.

        Returns
        -------
        STData
            New :class:`STData` object with the updated `good_frames`
            and `whitefield`.
        """
        if good_frames is None:
            good_frames = np.where(self.data.sum(axis=(1, 2)) > 0)[0]
        return {'good_frames': np.asarray(good_frames, dtype=np.int),
                'whitefield': None}

    @dict_to_object
    def mirror_data(self, axis: int=1) -> STData:
        """Return a new :class:`STData` object with the data mirrored
        along the given axis.

        Parameters
        ----------
        axis : int, optional
            Choose between the vertical axis (0) and
            the horizontal axis (1).

        Returns
        -------
        STData
            New :class:`STData` object with the updated `data` and
            `basis_vectors`.
        """
        if axis not in [0, 1]:
            raise ValueError('Axis must equal to 0 or 1')

        basis_vectors = np.copy(self.basis_vectors)
        basis_vectors[:, axis] *= -1.0

        roi = np.copy(self.roi)
        roi[2 * axis] = self.whitefield.shape[axis] - self.roi[2 * axis + 1]
        roi[2 * axis + 1] = self.whitefield.shape[axis] - self.roi[2 * axis]
        data_dict = {'basis_vectors': basis_vectors, 'roi': roi,
                     'pixel_translations': None}

        for attr, val in self.items():
            if val is not None and self.protocol.get_is_data(attr):
                data_dict[attr] = np.flip(val, axis=axis - 2)
        return data_dict

    @dict_to_object
    def update_mask(self, method: str='perc-bad', pmin: float=0., pmax: float=99.99,
                    vmin: int=0, vmax: int=65535, update: str='reset') -> STData:
        """Return a new :class:`STData` object with the updated
        bad pixels mask.

        Parameters
        ----------
        method : {'no-bad', 'range-bad', 'perc-bad'}, optional
            Bad pixels masking methods:

            * 'no-bad' (default) : No bad pixels.
            * 'range-bad' : Mask the pixels which values lie outside
              of (`vmin`, `vmax`) range.
            * 'perc-bad' : Mask the pixels which values lie outside
              of the (`pmin`, `pmax`) percentiles.
        vmin, vmax : float, optional
            Lower and upper intensity values of 'range-bad' masking
            method.
        pmin, pmax : float, optional
            Lower and upper percentage values of 'perc-bad' masking
            method.
        update : {'reset', 'multiply'}, optional
            Multiply the new mask and the old one if 'multiply',
            use the new one if 'reset'.

        Returns
        -------
        STData
            New :class:`STData` object with the updated `mask`.
        """
        data = self.get('data')
        if method == 'no-bad':
            mask = np.ones((self.good_frames.size, self.roi[1] - self.roi[0],
                            self.roi[3] - self.roi[2]), dtype=bool)
        elif method == 'range-bad':
            mask = (data >= vmin) & (data < vmax)
        elif method == 'perc-bad':
            offsets = (data - np.median(data))
            mask = (offsets >= np.percentile(offsets, pmin)) & \
                   (offsets <= np.percentile(offsets, pmax))
        else:
            ValueError('Invalid method keyword')

        mask_full = self.mask.copy()
        if update == 'reset':
            mask_full[self.good_frames, self.roi[0]:self.roi[1], self.roi[2]:self.roi[3]] = mask
        elif update == 'multiply':
            mask_full[self.good_frames, self.roi[0]:self.roi[1], self.roi[2]:self.roi[3]] *= mask
        else:
            raise ValueError('Invalid update keyword')

        return {'mask': mask_full, 'sigma': None, 'whitefield': None}

    @dict_to_object
    def make_whitefield(self) -> STData:
        """Return a new :class:`STData` object with the updated `whitefield`.

        Returns
        -------
        STData
            New :class:`STData` object with the updated `whitefield`.
        """
        return {'whitefield': None}

    @dict_to_object
    def update_defocus(self, defocus_x: float, defocus_y: Optional[float]=None) -> STData:
        """Return a new :class:`STData` object with the updated
        defocus distances `defocus_x` and `defocus_y` for
        the horizontal and vertical detector axes accordingly. Update
        `pixel_translations` based on the new defocus distances.

        Parameters
        ----------
        defocus_x : float
            Defocus distance for the horizontal detector axis [m].
        defocus_y : float, optional
            Defocus distance for the vertical detector axis [m].
            Equals to `defocus_x` if it's not provided.

        Returns
        -------
        STData
            New :class:`STData` object with the updated `defocus_y`,
            `defocus_x`, and `pixel_translations`.
        """
        if defocus_y is None:
            defocus_y = defocus_x

        pixel_map = self.pixel_map
        if defocus_y < 0.0 and pixel_map[0, 0, 0] < pixel_map[0, -1, 0]:
            pixel_map = np.flip(pixel_map, axis=1)
        if defocus_x < 0.0 and pixel_map[1, 0, 0] < pixel_map[1, 0, -1]:
            pixel_map = np.flip(pixel_map, axis=2)
        return {'defocus_y': defocus_y, 'defocus_x': defocus_x,
                'pixel_map': pixel_map, 'pixel_translations': None}

    def update_phase(self, st_obj: SpeckleTracking) -> None:
        """Update `pixel_aberrations`, `phase`, and `reference_image`
        based on :class:`SpeckleTracking` object `st_obj` data. `st_obj`
        must be derived from the :class:`STData` object, an error is
        raised otherwise.

        Parameters
        ----------
        st_obj : SpeckleTracking
            :class:`SpeckleTracking` object derived from the :class:`STData` object.

        Raises
        ------
        ValueError
            If `st_obj` doesn't belong to the :class:`STData` object.
        """
        if st_obj.parent() is not self:
            raise ValueError("the SpeckleTracking object doesn't belong to the data container")
        # Update phase, pixel_aberrations, and reference_image
        dpm_y, dpm_x = (st_obj.pixel_map - self.get('pixel_map'))
        dpm_y -= dpm_y.mean()
        dpm_x -= dpm_x.mean()
        self.pixel_aberrations = np.zeros(self.pixel_map.shape, dtype=self.pixel_map.dtype)
        self.pixel_aberrations[:, self.roi[0]:self.roi[1], self.roi[2]:self.roi[3]] = np.stack((dpm_y, dpm_x))

        # Calculate magnification for horizontal and vertical axes
        mag_y = np.abs((self.distance + self.defocus_y) / self.defocus_y)
        mag_x = np.abs((self.distance + self.defocus_x) / self.defocus_x)

        # Calculate the distance between the reference and the detector plane
        dist_y = self.distance * (1 - mag_y**-1)
        dist_x = self.distance * (1 - mag_x**-1)

        # dTheta = delta_pix / distance / magnification * du
        # Phase = 2 * pi / wavelength * Integrate[dTheta, delta_pix]
        phase = ct_integrate(sy_arr=self.y_pixel_size**2 / dist_y / mag_y * dpm_y,
                             sx_arr=self.x_pixel_size**2 / dist_x / mag_x * dpm_x)
        phase *= 2.0 * np.pi / self.wavelength
        self.phase = np.zeros(self.whitefield.shape, dtype=self.pixel_map.dtypen)
        self.phase[self.roi[0]:self.roi[1], self.roi[2]:self.roi[3]] = phase
        self.reference_image = st_obj.reference_image

    def fit_phase(self, center: int=0, axis: int=1, max_order: int=2, xtol: float=1e-14,
                  ftol: float=1e-14, loss: str='cauchy') -> Dict[str, Union[float, np.ndarray]]:
        """Fit `pixel_aberrations` with the polynomial function
        using nonlinear least-squares algorithm. The function uses
        least-squares algorithm from :func:`scipy.optimize.least_squares`.

        Parameters
        ----------
        center : int, optional
            Index of the zerro scattering angle or direct
            beam pixel.
        axis : int, optional
            Axis along which `pixel_aberrations` is fitted.
        max_order : int, optional
            Maximum order of the polynomial model function.
        xtol : float, optional
            Tolerance for termination by the change of the independent variables.
        ftol : float, optional
            Tolerance for termination by the change of the cost function.
        loss : {'linear', 'soft_l1', 'huber', 'cauchy', 'arctan'}, optional
            Determines the loss function. The following keyword values are
            allowed:

            * 'linear' : ``rho(z) = z``. Gives a standard
              least-squares problem.
            * 'soft_l1' : ``rho(z) = 2 * ((1 + z)**0.5 - 1)``. The smooth
              approximation of l1 (absolute value) loss. Usually a good
              choice for robust least squares.
            * 'huber' : ``rho(z) = z if z <= 1 else 2*z**0.5 - 1``. Works
              similarly to 'soft_l1'.
            * 'cauchy' (default) : ``rho(z) = ln(1 + z)``. Severely weakens
              outliers influence, but may cause difficulties in optimization
              process.
            * 'arctan' : ``rho(z) = arctan(z)``. Limits a maximum loss on
              a single residual, has properties similar to 'cauchy'.

        Returns
        -------
        dict
            :class:`dict` with the following fields defined:

            * c_3 : Third order aberrations coefficient [rad / mrad^3].
            * c_4 : Fourth order aberrations coefficient [rad / mrad^4].
            * fit : Array of the polynomial function coefficients of the
              pixel aberrations fit.
            * ph_fit : Array of the polynomial function coefficients of
              the phase aberrations fit.
            * rel_err : Vector of relative errors of the fit coefficients.
            * r_sq : ``R**2`` goodness of fit.

        See Also
        --------
        AberrationsFit.fit - Full details of the aberrations fitting algorithm.
        """
        if not self._isphase:
            raise ValueError("'phase' is not defined inside the container.")
        return self.get_fit(center=center, axis=axis).fit(max_order=max_order,
                                                            xtol=xtol, ftol=ftol,
                                                            loss=loss)

    def defocus_sweep(self, defoci_x: np.ndarray, defoci_y: Optional[np.ndarray]=None, size: int=51,
                      extra_args: Dict[str, Union[float, bool, str]]={}, return_extra: bool=False,
                      verbose: bool=True) -> Union[List[float], Tuple[List[float], Dict[str, np.ndarray]]]:
        r"""Calculate a set of reference images for each defocus in `defoci` and
        return an average R-characteristic of an image (the higher the value the sharper
        reference image is). Return the intermediate results if `return_extra` is True.

        Parameters
        ----------
        defoci_x : numpy.ndarray
            Array of defocus distances along the horizontal detector axis [m].
        defoci_y : numpy.ndarray, optional
            Array of defocus distances along the vertical detector axis [m].
        size : int, optional
            Local variance filter size in pixels.
        extra_args : dict, optional
            Extra arguments parser to the :func:`STData.get_st` and
            :func:`SpeckleTracking.update_reference` methods. The following
            keyword values are allowed:

            * 'ds_y' : Reference image sampling interval in pixels along the
              horizontal axis. The default value is 1.0.
            * 'ds_x' : Reference image sampling interval in pixels along the
              vertical axis. The default value is 1.0.
            * 'aberrations' : Add `pixel_aberrations` to `pixel_map` of
              :class:`SpeckleTracking` object if it's True. The default value
              is False.
            * 'ff_correction' : Apply dynamic flatfield correction if it's True.
              The default value is False.
            * 'hval' : Kernel bandwidth in pixels for the reference image update.
              The default value is 1.0.
            * 'ref_method' : Choose the reference image update algorithm. The following keyword
              values are allowed:

              * 'KerReg' : Kernel regression algorithm.
              * 'LOWESS' : Local weighted linear regression.
              The default value is 'KerReg'.
        return_extra : bool, optional
            Return a dictionary with the intermediate results if True.

        Returns
        -------
        r_vals : list of floats
            Array of the average values of `reference_image` gradients squared.
        extra : dict
            Dictionary with the intermediate results. Only if `return_extra` is True.
            Contains the following data:

            * reference_image : The generated set of reference profiles.
            * r_images : The set of local variance images of reference profiles.

        Notes
        -----
        R-characteristic is called a local variance and is given by:

        .. math::
            R[i, j] = \frac{\sum_{i^{\prime} = -N / 2}^{N / 2}
            \sum_{j^{\prime} = -N / 2}^{N / 2} (I[i - i^{\prime}, j - j^{\prime}]
            - \bar{I}[i, j])^2}{\bar{I}^2[i, j]}

        where :math:`\bar{I}[i, j]` is a local mean and defined as follows:

        .. math::
            \bar{I}[i, j] = \frac{1}{N^2} \sum_{i^{\prime} = -N / 2}^{N / 2}
            \sum_{j^{\prime} = -N / 2}^{N / 2} I[i - i^{\prime}, j - j^{\prime}]

        See Also
        --------
        SpeckleTracking.update_reference : `reference_image` update algorithm.
        """
        if defoci_y is None:
            defoci_y = defoci_x.copy()

        ds_y = extra_args.get('ds_y', 1.0)
        ds_x = extra_args.get('ds_x', 1.0)
        aberrations = extra_args.get('aberrations', False)
        ff_correction = extra_args.get('ff_correction', False)
        hval = extra_args.get('hval', 1.0)
        ref_method = extra_args.get('ref_method', 'KerReg')

        r_vals = []
        extra = {'reference_image': [], 'r_image': []}
        kernel = np.ones(int(size)) / size
        st_obj = self.update_defocus(defoci_x.ravel()[0],
                                     defoci_y.ravel()[0]).get_st(ds_y=ds_y, ds_x=ds_x,
                                                                 aberrations=aberrations,
                                                                 ff_correction=ff_correction)

        for defocus_x, defocus_y in tqdm(zip(defoci_x.ravel(), defoci_y.ravel()),
                                           total=len(defoci_x), disable=not verbose,
                                           desc='Generating defocus sweep'):
            st_obj.di_pix *= np.abs(defoci_y.ravel()[0] / defocus_y)
            st_obj.dj_pix *= np.abs(defoci_x.ravel()[0] / defocus_x)
            st_obj.update_reference.inplace_update(hval=hval, method=ref_method)
            extra['reference_image'].append(st_obj.reference_image)
            mean = st_obj.reference_image.copy()
            mean_sq = st_obj.reference_image**2
            if st_obj.reference_image.shape[0] > size:
                mean = fft_convolve(mean, kernel, mode='reflect', axis=0,
                                    num_threads=self.num_threads)[size // 2:-size // 2]
                mean_sq = fft_convolve(mean_sq, kernel, mode='reflect', axis=0,
                                       num_threads=self.num_threads)[size // 2:-size // 2]
            if st_obj.reference_image.shape[1] > size:
                mean = fft_convolve(mean, kernel, mode='reflect', axis=1,
                                    num_threads=self.num_threads)[:, size // 2:-size // 2]
                mean_sq = fft_convolve(mean_sq, kernel, mode='reflect', axis=1,
                                       num_threads=self.num_threads)[:, size // 2:-size // 2]
            r_image = (mean_sq - mean**2) / mean**2
            extra['r_image'].append(r_image)
            r_vals.append(np.mean(r_image))

        if return_extra:
            return r_vals, extra
        return r_vals

    def get(self, attr: str, value: Optional[Any]=None) -> Any:
        """Return a dataset with `mask` and `roi` applied.
        Return `value` if the attribute is not found.

        Parameters
        ----------
        attr : str
            Attribute to fetch.
        value : object, optional
            Return if `attr` is not found.

        Returns
        -------
        numpy.ndarray or object
            `attr` dataset with `mask` and `roi` applied.
            `value` if `attr` is not found.
        """
        if attr in self:
            val = super(STData, self).get(attr)
            if not val is None:
                if self.protocol.get_is_data(attr):
                    val = val[..., self.roi[0]:self.roi[1], self.roi[2]:self.roi[3]]
                if attr in ['basis_vectors', 'flatfields', 'data', 'mask',
                            'pixel_translations', 'translations']:
                    val = val[self.good_frames]
            return val
        return value

    def get_st(self, ds_y: float=1.0, ds_x: float=1.0, aberrations: bool=False,
               ff_correction: bool=False) -> SpeckleTracking:
        """Return :class:`SpeckleTracking` object derived
        from the container. Return None if `defocus_x`
        or `defocus_y` doesn't exist in the container.

        Parameters
        ----------
        ds_y : float, optional
            Reference image sampling interval in pixels along the
            vertical axis.
        ds_x : float, optional
            Reference image sampling interval in pixels along the
            horizontal axis.
        aberrations : bool, optional
            Add `pixel_aberrations` to `pixel_map` of
            :class:`SpeckleTracking` object if it's True.
        ff_correction : bool, optional
            Apply dynamic flatfield correction if it's True.

        Returns
        -------
        SpeckleTracking
            An instance of :class:`SpeckleTracking` derived
            from the container. None if `defocus_x` or
            `defocus_y` are not defined.
        """
        if not self._isdefocus:
            raise ValueError("'defocus_x' is not defined inside the container.")

        data = np.ascontiguousarray(self.get('mask') * self.get('data'))
        pixel_map = np.ascontiguousarray(self.get('pixel_map'))
        if aberrations:
            pixel_map += self.get('pixel_aberrations')
        whitefield = np.ascontiguousarray(self.get('whitefield'))
        if ff_correction:
            flatfields = self.get('flatfields')
            if not flatfields is None:
                np.rint(data * np.where(flatfields > 0, whitefield / flatfields, 1.),
                        out=data, casting='unsafe')
        dij_pix = np.ascontiguousarray(np.swapaxes(self.get('pixel_translations'), 0, 1))
        return SpeckleTracking(parent=ref(self), data=data, dj_pix=dij_pix[1], di_pix=dij_pix[0],
                               num_threads=self.num_threads, pixel_map=pixel_map, sigma=self.sigma,
                               ds_y=ds_y, ds_x=ds_x, whitefield=whitefield)

    def get_fit(self, center: int=0, axis: int=1) -> AberrationsFit:
        """Return an :class:`AberrationsFit` object for
        parametric regression of the lens' aberrations
        profile. Return None if `defocus_x` or
        `defocus_y` doesn't exist in the container.

        Parameters
        ----------
        center : int, optional
            Index of the zerro scattering angle or direct
            beam pixel.
        axis : int, optional
            Detector axis along which the fitting is performed.

        Returns
        -------
        AberrationsFit or None
            An instance of :class:`AberrationsFit` class.
            None if `defocus_x` or `defocus_y` is None.
        """
        if not self._isphase:
            raise ValueError("'phase' or 'pixel_aberrations' are not defined inside the container.")

        data_dict = {attr: self.get(attr) for attr in AberrationsFit.attr_set if attr in self}
        if axis == 0:
            data_dict.update({attr: self.get(data_attr)
                              for attr, data_attr in AberrationsFit.y_lookup.items()})
        elif axis == 1:
            data_dict.update({attr: self.get(data_attr)
                              for attr, data_attr in AberrationsFit.x_lookup.items()})
        else:
            raise ValueError('invalid axis value: {:d}'.format(axis))

        data_dict['defocus'] = np.abs(data_dict['defocus'])
        if center <= self.roi[2 * axis]:
            data_dict['pixels'] = np.arange(self.roi[2 * axis],
                                            self.roi[2 * axis + 1]) - center
            data_dict['pixel_aberrations'] = data_dict['pixel_aberrations'][axis].mean(axis=1 - axis)
        elif center >= self.roi[2 * axis - 1] - 1:
            data_dict['pixels'] = center - np.arange(self.roi[2 * axis],
                                                     self.roi[2 * axis + 1])
            idxs = np.argsort(data_dict['pixels'])
            data_dict['pixel_aberrations'] = -data_dict['pixel_aberrations'][axis].mean(axis=1 - axis)[idxs]
            data_dict['pixels'] = data_dict['pixels'][idxs]
        else:
            raise ValueError('Origin must be outside of the region of interest')

        return AberrationsFit(parent=ref(self), **data_dict)

    def get_pca(self) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Perform the Principal Component Analysis [PCA]_ of the measured data and
        return a set of eigen flat fields (EFF).

        Returns
        -------
        cor_data : numpy.ndarray
            Background subtracted data.
        effs : numpy.ndarray
            Set of eigen flat fields.
        effs_var : numpy.ndarray
            Variance ratio for each EFF, that it describes.

        References
        ----------
        .. [PCA] Vincent Van Nieuwenhove, Jan De Beenhouwer, Francesco De Carlo,
                 Lucia Mancini, Federica Marone, and Jan Sijbers, "Dynamic intensity
                 normalization using eigen flat fields in X-ray imaging," Opt. Express
                 23, 27975-27989 (2015).
        """
        good_data, good_mask, good_wf = self.get('data'), self.get('mask'), self.get('whitefield')
        cor_data = np.zeros(good_data.shape, dtype=good_wf.dtype)
        np.subtract(good_data, good_wf, where=good_mask, out=cor_data)
        mat_svd = np.tensordot(cor_data, cor_data, axes=((1, 2), (1, 2)))
        eig_vals, eig_vecs = np.linalg.eig(mat_svd)
        effs = np.tensordot(eig_vecs, cor_data, axes=((0,), (0,)))
        return cor_data, effs, eig_vals / eig_vals.sum()

    @dict_to_object
    def update_flatfields(self, method: str='median', size: int=11, cor_data: Optional[np.ndarray]=None,
                          effs: Optional[np.ndarray]=None) -> STData:
        """Return a new :class:`STData` object with new
        flatfields. The flatfields are generated by the dint of
        median filtering or Principal Component Analysis [PCA]_.

        Parameters
        ----------
        method : {'median', 'pca'}, optional
            Method to generate the flatfields. The following keyword
            values are allowed:

            * 'median' : Median `data` along the first axis.
            * 'pca' : Generate a set of flatfields based on Eigen Flatfields
              `effs`. `effs` can be obtained with :func:`STData.get_pca`
              method.
        size : int, optional
            Size of the filter window in pixels used for the 'median' generation
            method.
        effs : np.ndarray, optional
            Set of Eigen flatfields used for the 'pca' generation method.

        Raises
        ------
        ValueError
            If the `method` keyword is invalid.
        AttributeError
            If the `whitefield` is absent in the :class:`STData` container
            when using the 'pca' generation method.
        ValuerError
            If `effs` were not provided when using the 'pca' generation method.

        Returns
        -------
        STData
            New :class:`STData` object with the updated `flatfields`.

        References
        ----------
        .. [PCA] Vincent Van Nieuwenhove, Jan De Beenhouwer, Francesco De Carlo,
                 Lucia Mancini, Federica Marone, and Jan Sijbers, "Dynamic
                 intensity normalization using eigen flat fields in X-ray
                 imaging," Opt. Express 23, 27975-27989 (2015).

        See Also
        --------
        STData.get_pca : Method to generate Eigen Flatfields.
        """
        good_wf = self.get('whitefield')
        if method == 'median':
            good_data = self.get('data')
            outliers = np.abs(good_data - good_wf) < 3 * np.sqrt(good_wf)
            good_flats = median_filter(good_data, size=(size, 1, 1), mask=outliers,
                                       num_threads=self.num_threads)
        elif method == 'pca':
            if cor_data is None:
                good_data, good_mask = self.get('data'), self.get('mask')
                cor_data = np.zeros(good_data.shape, dtype=good_wf.dtype)
                np.subtract(good_data, good_wf, where=good_mask, out=cor_data)
            if effs is None:
                raise ValueError('No eigen flat fields were provided')

            weights = np.tensordot(cor_data, effs, axes=((1, 2), (1, 2))) / \
                      np.sum(effs * effs, axis=(1, 2))
            good_flats = np.asarray(np.tensordot(weights, effs, axes=((1,), (0,))) + good_wf,
                                    dtype=good_data.dtype)
        else:
            raise ValueError('Invalid method argument')

        flatfields = np.zeros(self.data.shape, dtype=good_data.dtype)
        flatfields[self.good_frames, self.roi[0]:self.roi[1],
                    self.roi[2]:self.roi[3]] = good_flats
        return {'flatfields': flatfields}

    def write_cxi(self, cxi_file: h5py.File) -> None:
        """Write all the `attr` to a CXI file `cxi_file`.

        Parameters
        ----------
        cxi_file : h5py.File
            :class:`h5py.File` object of the CXI file.
        overwrite : bool, optional
            Overwrite the content of `cxi_file` file if it's True.

        Raises
        ------
        ValueError
            If `overwrite` is False and the data is already present
            in `cxi_file`.
        """
        for attr, data in self.items():
            if attr in self.protocol and data is not None:
                self.protocol.write_cxi(attr, data, cxi_file)
