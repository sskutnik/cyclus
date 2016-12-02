"""Python wrapper for cyclus."""
from __future__ import division, unicode_literals, print_function

# Cython imports
from libcpp.utility cimport pair as std_pair
from libcpp.set cimport set as std_set
from libcpp.map cimport map as std_map
from libcpp.vector cimport vector as std_vector
from libcpp.string cimport string as std_string
from cython.operator cimport dereference as deref
from cython.operator cimport preincrement as inc
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy
from libcpp cimport bool as cpp_bool

from binascii import hexlify
import uuid

cimport numpy as np
import numpy as np
import pandas as pd

# local imports
from cyclus cimport cpp_cyclus
from cyclus cimport cpp_typesystem
from cyclus.typesystem cimport py_to_any, db_to_py, uuid_cpp_to_py, \
    str_py_to_cpp


# startup numpy
np.import_array()
np.import_ufunc()


cdef class _Datum:

    def __cinit__(self):
        """Constructor for Datum type conversion."""
        self._free = False
        self.ptx = NULL

    def __dealloc__(self):
        """Datum destructor."""
        if self.ptx == NULL:
            return
        cdef cpp_cyclus.Datum* cpp_ptx
        if self._free:
            cpp_ptx = <cpp_cyclus.Datum*> self.ptx
            del cpp_ptx
            self.ptx = NULL

    def add_val(self, const char* field, value, shape=None, dbtype=cpp_typesystem.BLOB):
        """Adds Datum value to current record as the corresponding cyclus data type.

        Parameters
        ----------
        field : pointer to char/str
            The column name.
        value : object
            Value in table column.
        shape : list or tuple of ints
            Length of value.
        dbtype : cpp data type
            Data type as defined by cyclus typesystem

        Returns
        -------
        self : Datum
        """
        cdef int i, n
        cdef std_vector[int] cpp_shape
        cdef cpp_cyclus.hold_any v = py_to_any(value, dbtype)
        cdef std_string cfield
        if shape is None:
            (<cpp_cyclus.Datum*> self.ptx).AddVal(field, v)
        else:
            n = len(shape)
            cpp_shape.resize(n)
            for i in range(n):
                cpp_shape[i] = <int> shape[i]
            (<cpp_cyclus.Datum*> self.ptx).AddVal(field, v, &cpp_shape)
        return self

    def record(self):
        """Records the Datum."""
        (<cpp_cyclus.Datum*> self.ptx).Record()

    property title:
        """The datum name."""
        def __get__(self):
            s = (<cpp_cyclus.Datum*> self.ptx).title()
            return s


class Datum(_Datum):
    """Datum class."""


cdef class _FullBackend:

    def __cinit__(self):
        """Full backend C++ constructor"""
        self._tables = None

    def __dealloc__(self):
        """Full backend C++ destructor."""
        # Note that we have to do it this way since self.ptx is void*
        if self.ptx == NULL:
            return
        cdef cpp_cyclus.FullBackend * cpp_ptx = <cpp_cyclus.FullBackend *> self.ptx
        del cpp_ptx
        self.ptx = NULL

    def query(self, table, conds=None):
        """Queries a database table.

        Parameters
        ----------
        table : str
            The table name.
        conds : iterable, optional
            A list of conditions.

        Returns
        -------
        results : pd.DataFrame
            Pandas DataFrame the represents the table
        """
        cdef int i, j
        cdef int nrows, ncols
        cdef std_string tab = str(table).encode()
        cdef std_string field
        cdef cpp_cyclus.QueryResult qr
        cdef std_vector[cpp_cyclus.Cond] cpp_conds
        cdef std_vector[cpp_cyclus.Cond]* conds_ptx
        cdef std_map[std_string, cpp_cyclus.DbTypes] coltypes
        # set up the conditions
        if conds is None:
            conds_ptx = NULL
        else:
            coltypes = (<cpp_cyclus.FullBackend*> self.ptx).ColumnTypes(tab)
            for cond in conds:
                cond0 = cond[0].encode()
                cond1 = cond[1].encode()
                field = std_string(<const char*> cond0)
                if coltypes.count(field) == 0:
                    continue  # skips non-existent columns
                cpp_conds.push_back(cpp_cyclus.Cond(field, cond1,
                    py_to_any(cond[2], coltypes[field])))
            if cpp_conds.size() == 0:
                conds_ptx = NULL
            else:
                conds_ptx = &cpp_conds
        # query, convert, and return
        qr = (<cpp_cyclus.FullBackend*> self.ptx).Query(tab, conds_ptx)
        nrows = qr.rows.size()
        ncols = qr.fields.size()
        cdef dict res = {}
        cdef list fields = []
        for j in range(ncols):
            res[j] = []
            f = qr.fields[j]
            fields.append(f.decode())
        for i in range(nrows):
            for j in range(ncols):
                res[j].append(db_to_py(qr.rows[i][j], qr.types[j]))
        res = {fields[j]: v for j, v in res.items()}
        results = pd.DataFrame(res, columns=fields)
        return results

    property tables:
        """Retrieves the set of tables present in the database."""
        def __get__(self):
            if self._tables is not None:
                return self._tables
            cdef std_set[std_string] ctabs = \
                (<cpp_cyclus.FullBackend*> self.ptx).Tables()
            cdef std_set[std_string].iterator it = ctabs.begin()
            cdef set tabs = set()
            while it != ctabs.end():
                tab = deref(it)
                tabs.add(tab.decode())
                inc(it)
            self._tables = tabs
            return self._tables

        def __set__(self, value):
            self._tables = value


class FullBackend(_FullBackend, object):
    """Full backend cyclus database interface."""

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()


cdef class _SqliteBack(_FullBackend):

    def __cinit__(self, path):
        """Full backend C++ constructor"""
        cdef std_string cpp_path = str(path).encode()
        self.ptx = new cpp_cyclus.SqliteBack(cpp_path)

    def __dealloc__(self):
        """Full backend C++ destructor."""
        # Note that we have to do it this way since self.ptx is void*
        if self.ptx == NULL:
            return
        cdef cpp_cyclus.SqliteBack * cpp_ptx = <cpp_cyclus.SqliteBack *> self.ptx
        del cpp_ptx
        self.ptx = NULL

    def flush(self):
        """Flushes the database to disk."""
        (<cpp_cyclus.SqliteBack*> self.ptx).Flush()

    def close(self):
        """Closes the backend, flushing it in the process."""
        self.flush()  # just in case
        (<cpp_cyclus.SqliteBack*> self.ptx).Close()

    property name:
        """The name of the database."""
        def __get__(self):
            name = (<cpp_cyclus.SqliteBack*> self.ptx).Name()
            name = name.decode()
            return name


class SqliteBack(_SqliteBack, FullBackend):
    """SQLite backend cyclus database interface."""


cdef class _Hdf5Back(_FullBackend):

    def __cinit__(self, path):
        """Hdf5 backend C++ constructor"""
        cdef std_string cpp_path = str(path).encode()
        self.ptx = new cpp_cyclus.Hdf5Back(cpp_path)

    def __dealloc__(self):
        """Full backend C++ destructor."""
        # Note that we have to do it this way since self.ptx is void*
        if self.ptx == NULL:
            return
        cdef cpp_cyclus.Hdf5Back * cpp_ptx = <cpp_cyclus.Hdf5Back *> self.ptx
        del cpp_ptx
        self.ptx = NULL

    def flush(self):
        """Flushes the database to disk."""
        (<cpp_cyclus.Hdf5Back*> self.ptx).Flush()

    def close(self):
        """Closes the backend, flushing it in the process."""
        (<cpp_cyclus.Hdf5Back*> self.ptx).Close()

    property name:
        """The name of the database."""
        def __get__(self):
            name = (<cpp_cyclus.Hdf5Back*> self.ptx).Name()
            name = name.decode()
            return name


class Hdf5Back(_Hdf5Back, FullBackend):
    """HDF5 backend cyclus database interface."""


cdef class _Recorder:

    def __cinit__(self, bint inject_sim_id=True):
        """Recorder C++ constructor"""
        self.ptx = new cpp_cyclus.Recorder(<cpp_bool> inject_sim_id)

    def __dealloc__(self):
        """Recorder C++ destructor."""
        if self.ptx == NULL:
            return
        self.close()
        # Note that we have to do it this way since self.ptx is void*
        cdef cpp_cyclus.Recorder * cpp_ptx = <cpp_cyclus.Recorder *> self.ptx
        del cpp_ptx
        self.ptx = NULL

    property dump_count:
        """The frequency of recording."""
        def __get__(self):
            return (<cpp_cyclus.Recorder*> self.ptx).dump_count()

        def __set__(self, value):
            (<cpp_cyclus.Recorder*> self.ptx).set_dump_count(<unsigned int> value)

    property sim_id:
        """The simulation id of the recorder."""
        def __get__(self):
            return uuid_cpp_to_py((<cpp_cyclus.Recorder*> self.ptx).sim_id())

    property inject_sim_id:
        """Whether or not to inject the simulation id into the tables."""
        def __get__(self):
            return (<cpp_cyclus.Recorder*> self.ptx).inject_sim_id()

        def __set__(self, value):
            (<cpp_cyclus.Recorder*> self.ptx).inject_sim_id(<bint> value)

    def new_datum(self, title):
        """Registers a backend with the recorder."""
        cdef std_string cpp_title = str_py_to_cpp(title)
        cdef _Datum d = Datum(new=False)
        (<_Datum> d).ptx = (<cpp_cyclus.Recorder*> self.ptx).NewDatum(cpp_title)
        return d

    def register_backend(self, backend):
        """Registers a backend with the recorder."""
        cdef cpp_cyclus.RecBackend* b
        if isinstance(backend, Hdf5Back):
            b = <cpp_cyclus.RecBackend*> (
                <cpp_cyclus.Hdf5Back*> (<_Hdf5Back> backend).ptx)
        elif isinstance(backend, SqliteBack):
            b = <cpp_cyclus.RecBackend*> (
                <cpp_cyclus.SqliteBack*> (<_SqliteBack> backend).ptx)
        (<cpp_cyclus.Recorder*> self.ptx).RegisterBackend(b)

    def flush(self):
        """Flushes the recorder to disk."""
        (<cpp_cyclus.Recorder*> self.ptx).Flush()

    def close(self):
        """Closes the recorder."""
        (<cpp_cyclus.Recorder*> self.ptx).Close()


class Recorder(_Recorder, object):
    """Cyclus recorder interface."""

#
# Agent Spec
#
cdef class _AgentSpec:

    def __cinit__(self, spec=None, lib=None, agent=None, alias=None):
        cdef std_string cpp_spec, cpp_lib, cpp_agent, cpp_alias
        if spec is None:
            self.ptx = new cpp_cyclus.AgentSpec()
        elif lib is None:
            cpp_spec = str_py_to_cpp(spec)
            self.ptx = new cpp_cyclus.AgentSpec(cpp_spec)
        else:
            cpp_spec = str_py_to_cpp(spec)
            cpp_lib = str_py_to_cpp(lib)
            cpp_agent = str_py_to_cpp(agent)
            cpp_alias = str_py_to_cpp(alias)
            self.ptx = new cpp_cyclus.AgentSpec(cpp_spec, cpp_lib,
                                                cpp_agent, cpp_alias)

    def __dealloc__(self):
        del self.ptx

    def __str__(self):
        cdef std_string cpp_rtn = self.ptx.str()
        rtn = cpp_rtn
        return rtn

    def sanatize(self):
        cdef std_string cpp_rtn = self.ptx.Sanatize()
        rtn = cpp_rtn
        return rtn

    @property
    def path(self)
        cdef std_string cpp_rtn = self.ptx.path()
        rtn = cpp_rtn
        return rtn

    @property
    def lib(self)
        cdef std_string cpp_rtn = self.ptx.lib()
        rtn = cpp_rtn
        return rtn

    @property
    def agent(self)
        cdef std_string cpp_rtn = self.ptx.agent()
        rtn = cpp_rtn
        return rtn

    @property
    def alias(self)
        cdef std_string cpp_rtn = self.ptx.alias()
        rtn = cpp_rtn
        return rtn


class AgentSpec(_AgentSpec):
    """AgentSpec C++ wrapper

    Parameters
    ----------
    spec : str or None, optional
        This repesents either the full string form of the spec or
        just the path.
    lib : str or None, optional
    agent : str or None, optional
    alias : str or None, optional
    """
