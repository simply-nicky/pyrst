"""Examples
--------
Generate the default built-in log protocol:

>>> import pyrost as rst
>>> rst.LogProtocol()
{'log_keys': {'det_dist': ['Session logged attributes', 'Z-LENSE-DOWN_det_dist'],
'exposure': ['Type: Method', 'Exposure'], 'n_steps': ['Type: Scan', 'Points count'],
'...': '...'}, 'datatypes': {'det_dist': 'float', 'exposure': 'float', 'n_steps':
'int', '...': '...'}}
"""
import os
import re
import numpy as np
from .ini_parser import ROOT_PATH, INIParser
from .cxi_protocol import CXIProtocol, CXILoader
from .data_processing import STData

LOG_PROTOCOL = os.path.join(ROOT_PATH, 'config/log_protocol.ini')

class LogProtocol(INIParser):
    """Log file protocol class. Contains log file keys to retrieve
    and the data types of the corresponding values.

    Parameters
    ----------
    datatypes : dict, optional
        Dictionary with attributes' datatypes. 'float', 'int', 'bool',
        or 'str' are allowed.
    log_keys : dict, optional
        Dictionary with attributes' log file keys.

    Attributes
    ----------
    datatypes : dict
        Dictionary with attributes' datatypes. 'float', 'int', 'bool',
        or 'str' are allowed.
    log_keys : dict
        Dictionary with attributes' log file keys.

    See Also
    --------
    protocol : Full list of data attributes and configuration
        parameters.
    """
    attr_dict = {'log_keys': ('ALL',), 'datatypes': ('ALL',)}
    fmt_dict = {'log_keys': 'str', 'datatypes': 'str'}
    unit_dict = {'mm': 1e-3, 'µm': 1e-6, 'nm': 1e-9, 'pm': 1e-12}

    def __init__(self, log_keys=None, datatypes=None):
        if log_keys is None:
            log_keys = self._import_ini(LOG_PROTOCOL)['log_keys']
        if datatypes is None:
            datatypes = self._import_ini(LOG_PROTOCOL)['datatypes']
        log_keys = {attr: val for attr, val in log_keys.items() if attr in datatypes}
        datatypes = {attr: val for attr, val in datatypes.items() if attr in log_keys}
        super(LogProtocol, self).__init__(log_keys=log_keys, datatypes=datatypes)

    @classmethod
    def import_default(cls, datatypes=None, log_keys=None):
        """Return the default :class:`LogProtocol` object. Extra arguments
        override the default values if provided.

        Parameters
        ----------
        datatypes : dict, optional
            Dictionary with attributes' datatypes. 'float', 'int', or 'bool'
            are allowed. Initialized with `ini_file` if None.
        log_keys : dict, optional
            Dictionary with attributes' log file keys. Initialized with
            `ini_file` if None.

        Returns
        -------
        LogProtocol
            A :class:`LogProtocol` object with the default parameters.

        See Also
        --------
        log_protocol : more details about the default CXI protocol.
        """
        return cls.import_ini(LOG_PROTOCOL, datatypes, log_keys)

    @classmethod
    def import_ini(cls, ini_file, datatypes=None, log_keys=None):
        """Initialize a :class:`LogProtocol` object class with an
        ini file.

        Parameters
        ----------
        ini_file : str
            Path to the ini file. Load the default log protocol if None.
        datatypes : dict, optional
            Dictionary with attributes' datatypes. 'float', 'int', or 'bool'
            are allowed. Initialized with `ini_file` if None.
        log_keys : dict, optional
            Dictionary with attributes' log file keys. Initialized with
            `ini_file` if None.

        Returns
        -------
        LogProtocol
            A :class:`LogProtocol` object with all the attributes imported
            from the ini file.
        """
        kwargs = cls._import_ini(ini_file)
        if not datatypes is None:
            kwargs['datatypes'].update(**datatypes)
        if not log_keys is None:
            kwargs['log_keys'].update(**log_keys)
        return cls(datatypes=kwargs['datatypes'], log_keys=kwargs['log_keys'])

    @classmethod
    def _get_unit(cls, key):
        for unit_key in cls.unit_dict:
            if unit_key in key:
                return cls.unit_dict[unit_key]
        return 1.

    def load_attributes(self, path):
        """Return attributes' values from a log file at
        the given `path`.

        Parameters
        ----------
        path : str
            Path to the log file.

        Returns
        -------
        attr_dict : dict
            Dictionary with the attributes retrieved from
            the log file.
        """
        if not isinstance(path, str):
            raise ValueError('path must be a string')
        with open(path, 'r') as log_file:
            log_str = ''
            for line in log_file:
                if line.startswith('# '):
                    log_str += line.strip('# ')

        # Divide log into sectors
        parts_list = [part for part in re.split('(' + \
                     '|'.join([key[0] for key in self.log_keys.values()]) + \
                     '|--------------------------------)\n*', log_str) if part]

        # List all the sector names
        part_keys = [part_key for part_key, _ in self.log_keys.values()]

        # Rearange sectors into a dictionary
        parts = {}
        for idx, part in enumerate(parts_list):
            if part in part_keys:
                if part == 'Session logged attributes':
                    attr_keys, attr_vals = parts_list[idx + 1].strip('\n').split('\n')
                    parts['Session logged attributes'] = ''
                    for key, val in zip(attr_keys.split(';'), attr_vals.split(';')):
                        parts['Session logged attributes'] += key + ': ' + val + '\n'
                else:
                    val = parts_list[idx + 1]
                    match = re.search(r'Device:.*\n', val)
                    if match:
                        name = match[0].split(': ')[-1][:-1]
                        parts[part + ', ' + name] = val

        # Populate attributes dictionary
        attr_dict = {part_name: {} for part_name in parts}
        for part_name, part in parts.items():
            for attr, [part_key, log_key] in self.log_keys.items():
                if part_key in part_name:
                    # Find the attribute's mention and divide it into a key and value pair
                    raw_str = re.search(log_key + r'.*\n', part)[0]
                    raw_val = raw_str.strip('\n').split(': ')[1]
                    # Extract a number string
                    val_num = re.search(r'\d+[.]*\d*', raw_val)
                    dtype = self.known_types[self.datatypes[attr]]
                    attr_dict[part_name][attr] = dtype(val_num[0] if val_num else raw_val)
                    # Apply unit conversion if needed
                    if np.issubdtype(dtype, np.floating):
                        attr_dict[part_name][attr] *= self._get_unit(raw_str)
        return attr_dict

    def load_data(self, path):
        """Retrieve the main data array from the log file.

        Parameters
        ----------
        path : str
            Path to the log file.

        Returns
        -------
        data : dict
            Dictionary with data fields and their names retrieved
            from the log file.
        """
        with open(path, 'r') as log_file:
            for line in log_file:
                if line.startswith('# '):
                    keys_line = line.strip('# ')
                else:
                    data_line = line
                    break

        keys = keys_line.strip('\n').split(';')
        data_strings = data_line.strip('\n').split(';')

        dtypes = {'names': [], 'formats': []}
        converters = {}
        for idx, (key, val) in enumerate(zip(keys, data_strings)):
            dtypes['names'].append(key)
            if 'float' in key:
                dtypes['formats'].append(np.float)
                if any(unit_key in key for unit_key in self.unit_dict):
                    converters[idx] = lambda item, key=key: self._get_unit(key) * float(item)
            elif 'int' in key:
                if any(unit_key in key for unit_key in self.unit_dict):
                    converters[idx] = lambda item, key=key: self._get_unit(key) * float(item)
                    dtypes['formats'].append(np.float)
                else:
                    dtypes['formats'].append(np.int)
            elif 'Array' in key:
                dtypes['formats'].append(np.ndarray)
                if any(unit_key in key for unit_key in self.unit_dict):
                    converters[idx] = lambda item, key=key: np.array([float(part) * self._get_unit(key)
                                                                      for part in item.strip(b'[]').split(b',')])
                converters[idx] = lambda item: np.array([float(part) for part in item.strip(b'[]').split(b',')])
            else:
                dtypes['formats'].append('<S' + str(len(val)))

        return dict(zip(keys, np.loadtxt(path, delimiter=';',
                                         converters=converters,
                                         dtype=dtypes, unpack=True)))

def cxi_converter_sigray(scan_num, target='Mo', distance=2.):
    """Convert measured frames and log files from the
    Sigray laboratory to a :class:`pyrost.STData` data
    container.

    Parameters
    ----------
    scan_num : int
        Scan number.
    target : {'Mo', 'Cu', 'Rh'}, optional
        Sigray X-ray source target used.
    distance : float, optional
        Detector distance in meters.

    Returns
    -------
    STData
        Data container with the extracted data.
    """
    wl_dict = {'Mo': 7.092917530503447e-11, 'Cu': 1.5498024804150033e-10,
               'Rh': 6.137831605603974e-11}

    h5_prt = CXIProtocol(default_paths={'data': 'entry/instrument/detector/data',
                                        'x_pixel_size': 'entry/instrument/detector/x_pixel_size',
                                        'y_pixel_size': 'entry/instrument/detector/y_pixel_size'},
                         datatypes={'data': 'float', 'x_pixel_size': 'float',
                                    'y_pixel_size': 'float'})
    cxi_prt = CXIProtocol()
    log_prt = LogProtocol()
    cxi_loader = CXILoader(h5_prt)

    fs_vec = np.array([0., -1., 0.])
    ss_vec = np.array([1., 0., 0.])

    log_path = f'/gpfs/cfel/cxi/labs/MLL-Sigray/scan-logs/Scan_{scan_num:d}.log'
    dir_path = f'/gpfs/cfel/cxi/labs/MLL-Sigray/scan-frames/Scan_{scan_num:d}'
    h5_files = [os.path.join(dir_path, path) for path in os.listdir(dir_path)
                if path.endswith('Lambda.nxs')]

    data = np.concatenate(list(cxi_loader.load_data(h5_files).values()), axis=-3)
    attrs = cxi_loader.load_attributes(h5_files[0])
    log_attrs = log_prt.load_attributes(log_path)
    log_data = log_prt.load_data(log_path)

    n_steps = np.prod([attrs['n_steps'] for key, attrs in log_attrs.items() if 'Type: Scan' in key])
    pix_vec = np.tile(np.array([[attrs['x_pixel_size'], attrs['y_pixel_size'], 0]]),
                      (n_steps, 1)) * 1e-6
    basis_vectors = np.stack([pix_vec * ss_vec, pix_vec * fs_vec], axis=1)

    translations = np.tile([[log_attrs['Session logged attributes']['x_sample'],
                            log_attrs['Session logged attributes']['y_sample'],
                            log_attrs['Session logged attributes']['z_sample']]],
                        (n_steps, 1))
    for data_key in log_data:
        if 'X-SAM' in data_key:
            translations[:, 0] = log_data[data_key]
        if 'Y-SAM' in data_key:
            translations[:, 1] = log_data[data_key]

    return STData(basis_vectors=basis_vectors, data=data, distance=distance,
                  translations=translations, wavelength=wl_dict[target],
                  x_pixel_size=attrs['x_pixel_size'] * 1e-6,
                  y_pixel_size=attrs['y_pixel_size'] * 1e-6, protocol=cxi_prt)
