"""Feature extraction"""

import logging

import numpy as np
cimport numpy as np

from rasterio._io cimport InMemoryRaster
from rasterio cimport _gdal, _ogr, _io
from rasterio import dtypes
from rasterio.enums import MergeAlg


log = logging.getLogger(__name__)


def _shapes(image, mask, connectivity, transform):
    """
    Return a generator of (polygon, value) for each each set of adjacent pixels
    of the same value.

    Parameters
    ----------
    image : numpy ndarray or rasterio Band object
        (RasterReader, bidx namedtuple).
        Data type must be one of rasterio.int16, rasterio.int32,
        rasterio.uint8, rasterio.uint16, or rasterio.float32.
    mask : numpy ndarray or rasterio Band object
        Values of False or 0 will be excluded from feature generation
        Must evaluate to bool (rasterio.bool_ or rasterio.uint8)
    connectivity : int
        Use 4 or 8 pixel connectivity for grouping pixels into features
    transform : Affine transformation
        If not provided, feature coordinates will be generated based on pixel
        coordinates

    Returns
    -------
    Generator of (polygon, value)
        Yields a pair of (polygon, value) for each feature found in the image.
        Polygons are GeoJSON-like dicts and the values are the associated value
        from the image, in the data type of the image.
        Note: due to floating point precision issues, values returned from a
        floating point image may not exactly match the original values.

    """

    cdef int retval, rows, cols
    cdef void *hband = NULL
    cdef void *hmaskband = NULL
    cdef void *hfdriver = NULL
    cdef void *hfs = NULL
    cdef void *hlayer = NULL
    cdef void *fielddefn = NULL
    cdef _io.RasterReader rdr
    cdef _io.RasterReader mrdr
    cdef char **options = NULL

    cdef InMemoryRaster mem_ds = None
    cdef InMemoryRaster mask_ds = None
    cdef bint is_float = np.dtype(image.dtype).kind == 'f'
    cdef int fieldtp = 2 if is_float else 0

    valid_dtypes = ('int16', 'int32', 'uint8', 'uint16', 'float32')

    if np.dtype(image.dtype).name not in valid_dtypes:
        raise ValueError('image dtype must be one of: %s'
                         % (', '.join(valid_dtypes)))

    if connectivity not in (4, 8):
        raise ValueError("Connectivity Option must be 4 or 8")

    if dtypes.is_ndarray(image):
        mem_ds = InMemoryRaster(image, transform)
        hband = mem_ds.band
    elif isinstance(image, tuple):
        rdr = image.ds
        hband = rdr.band(image.bidx)
    else:
        raise ValueError("Invalid source image")

    if mask is not None:
        if mask.shape != image.shape:
            raise ValueError("Mask must have same shape as image")

        if np.dtype(mask.dtype).name not in ('bool', 'uint8'):
            raise ValueError("Mask must be dtype rasterio.bool_ or "
                             "rasterio.uint8")

        if dtypes.is_ndarray(mask):
            # A boolean mask must be converted to uint8 for GDAL
            mask_ds = InMemoryRaster(mask.astype('uint8'), transform)
            hmaskband = mask_ds.band

        elif isinstance(mask, tuple):
            mrdr = mask.ds
            hmaskband = mrdr.band(mask.bidx)

    # Create an in-memory feature store.
    hfdriver = _ogr.OGRGetDriverByName("Memory")
    if hfdriver == NULL:
        raise ValueError("NULL driver")
    hfs = _ogr.OGR_Dr_CreateDataSource(hfdriver, "temp", NULL)
    if hfs == NULL:
        raise ValueError("NULL feature dataset")

    # And a layer.
    hlayer = _ogr.OGR_DS_CreateLayer(hfs, "polygons", NULL, 3, NULL)
    if hlayer == NULL:
        raise ValueError("NULL layer")

    fielddefn = _ogr.OGR_Fld_Create("image_value", fieldtp)
    if fielddefn == NULL:
        raise ValueError("NULL field definition")
    _ogr.OGR_L_CreateField(hlayer, fielddefn, 1)
    _ogr.OGR_Fld_Destroy(fielddefn)

    if connectivity == 8:
        options = _gdal.CSLSetNameValue(options, "8CONNECTED", "8")

    if is_float:
        _gdal.GDALFPolygonize(hband, hmaskband, hlayer, 0, options, NULL, NULL)
    else:
        _gdal.GDALPolygonize(hband, hmaskband, hlayer, 0, options, NULL, NULL)

    # Yield Fiona-style features
    cdef ShapeIterator shape_iter = ShapeIterator()
    shape_iter.hfs = hfs
    shape_iter.hlayer = hlayer
    shape_iter.fieldtp = fieldtp
    for s, v in shape_iter:
        yield s, v

    if mem_ds is not None:
        mem_ds.close()
    if mask_ds is not None:
        mask_ds.close()
    if hfs != NULL:
        _ogr.OGR_DS_Destroy(hfs)
    if options:
        _gdal.CSLDestroy(options)


def _sieve(image, size, out, mask, connectivity):
    """
    Replaces small polygons in `image` with the value of their largest
    neighbor.  Polygons are found for each set of neighboring pixels of the
    same value.

    Parameters
    ----------
    image : numpy ndarray or rasterio Band object
        (RasterReader, bidx namedtuple)
        Must be of type rasterio.int16, rasterio.int32, rasterio.uint8,
        rasterio.uint16, or rasterio.float32.
    size : int
        minimum polygon size (number of pixels) to retain.
    out : numpy ndarray
        Array of same shape and data type as `image` in which to store results.
    mask : numpy ndarray or rasterio Band object
        Values of False or 0 will be excluded from feature generation.
        Must evaluate to bool (rasterio.bool_ or rasterio.uint8)
    connectivity : int
        Use 4 or 8 pixel connectivity for grouping pixels into features.

    """

    cdef int retval, rows, cols
    cdef InMemoryRaster in_mem_ds = None
    cdef InMemoryRaster out_mem_ds = None
    cdef InMemoryRaster mask_mem_ds = None
    cdef void *in_band = NULL
    cdef void *out_band = NULL
    cdef void *mask_band = NULL
    cdef _io.RasterReader rdr
    cdef _io.RasterUpdater udr
    cdef _io.RasterReader mask_reader

    valid_dtypes = ('int16', 'int32', 'uint8', 'uint16')

    if np.dtype(image.dtype).name not in valid_dtypes:
        valid_types_str = ', '.join(('rasterio.{0}'.format(t) for t
                                     in valid_dtypes))
        raise ValueError('image dtype must be one of: %s' % valid_types_str)

    if size <= 0:
        raise ValueError('size must be greater than 0')
    elif type(size) == float:
        raise ValueError('size must be an integer number of pixels')
    elif size > (image.shape[0] * image.shape[1]):
        raise ValueError('size must be smaller than size of image')

    if connectivity not in (4, 8):
        raise ValueError('connectivity must be 4 or 8')

    if out.shape != image.shape:
        raise ValueError('out raster shape must be same as image shape')

    if np.dtype(image.dtype).name != np.dtype(out.dtype).name:
        raise ValueError('out raster must match dtype of image')

    if dtypes.is_ndarray(image):
        in_mem_ds = InMemoryRaster(image)
        in_band = in_mem_ds.band
    elif isinstance(image, tuple):
        rdr = image.ds
        in_band = rdr.band(image.bidx)
    else:
        raise ValueError("Invalid source image")

    if dtypes.is_ndarray(out):
        log.debug("out array: %r", out)
        out_mem_ds = InMemoryRaster(out)
        out_band = out_mem_ds.band
    elif isinstance(out, tuple):
        udr = out.ds
        out_band = udr.band(out.bidx)
    else:
        raise ValueError("Invalid out image")

    if mask is not None:
        if mask.shape != image.shape:
            raise ValueError("Mask must have same shape as image")

        if np.dtype(mask.dtype) not in ('bool', 'uint8'):
            raise ValueError("Mask must be dtype rasterio.bool_ or "
                             "rasterio.uint8")

        if dtypes.is_ndarray(mask):
            # A boolean mask must be converted to uint8 for GDAL
            mask_mem_ds = InMemoryRaster(mask.astype('uint8'))
            mask_band = mask_mem_ds.band

        elif isinstance(mask, tuple):
            mask_reader = mask.ds
            mask_band = mask_reader.band(mask.bidx)

    _gdal.GDALSieveFilter(
        in_band,
        mask_band,
        out_band,
        size,
        connectivity,
        NULL,
        NULL,
        NULL
    )

    # Read from out_band into out
    _io.io_auto(out, out_band, False)

    if in_mem_ds is not None:
        in_mem_ds.close()
    if out_mem_ds is not None:
        out_mem_ds.close()
    if mask_mem_ds is not None:
        mask_mem_ds.close()


def _rasterize(shapes, image, transform, all_touched, merge_alg):
    """
    Burns input geometries into `image`.

    Parameters
    ----------
    shapes : iterable of (geometry, value) pairs
        `geometry` is a GeoJSON-like object.
    image : numpy ndarray
        Array in which to store results.
    transform : Affine transformation object, optional
        Transformation from pixel coordinates of `image` to the
        coordinate system of the input `shapes`. See the `transform`
        property of dataset objects.
    all_touched : boolean, optional
        If True, all pixels touched by geometries will be burned in.
        If false, only pixels whose center is within the polygon or
        that are selected by Bresenham's line algorithm will be burned
        in.
    merge_alg : str, required
        'REPLACE' (the default) or 'ADD'
    """

    cdef int retval
    cdef size_t i
    cdef size_t num_geometries = 0
    cdef void **ogr_geoms = NULL
    cdef char **options = NULL
    cdef double *pixel_values = NULL  # requires one value per geometry
    cdef InMemoryRaster mem

    try:
        if all_touched:
            options = _gdal.CSLSetNameValue(options, "ALL_TOUCHED", "TRUE")
        merge_algorithm = MergeAlg[merge_alg].value.encode('utf-8')
        options = _gdal.CSLSetNameValue(options, "MERGE_ALG", merge_algorithm)

        # GDAL needs an array of geometries.
        # For now, we'll build a Python list on the way to building that
        # C array. TODO: make this more efficient.
        all_shapes = list(shapes)
        num_geometries = len(all_shapes)

        ogr_geoms = <void **>_gdal.CPLMalloc(num_geometries * sizeof(void*))
        pixel_values = <double *>_gdal.CPLMalloc(
                            num_geometries * sizeof(double))

        for i, (geometry, value) in enumerate(all_shapes):
            try:
                ogr_geoms[i] = OGRGeomBuilder().build(geometry)
                pixel_values[i] = <double>value
            except:
                log.error("Geometry %r at index %d with value %d skipped",
                    geometry, i, value)

        with InMemoryRaster(image, transform) as mem:
            _gdal.GDALRasterizeGeometries(
                        mem.dataset, 1, mem.band_ids,
                        num_geometries, ogr_geoms,
                        NULL, mem.transform, pixel_values,
                        options, NULL, NULL)

            # Read in-memory data back into image
            image = mem.read()

    finally:
        for i in range(num_geometries):
            _deleteOgrGeom(ogr_geoms[i])
        _gdal.CPLFree(ogr_geoms)
        _gdal.CPLFree(pixel_values)
        if options:
            _gdal.CSLDestroy(options)


def _explode(coords):
    """Explode a GeoJSON geometry's coordinates object and yield
    coordinate tuples. As long as the input is conforming, the type of
    the geometry doesn't matter.  From Fiona 1.4.8"""
    for e in coords:
        if isinstance(e, (float, int)):
            yield coords
            break
        else:
            for f in _explode(e):
                yield f


def _bounds(geometry):
    """Bounding box of a GeoJSON geometry.  
    From Fiona 1.4.8 with updates here to handle feature collections.
    TODO: add to Fiona.
    """

    if 'features' in geometry:
        xmins = []
        ymins = []
        xmaxs = []
        ymaxs = []
        for feature in geometry['features']:
            xmin, ymin, xmax, ymax = _bounds(feature['geometry'])
            xmins.append(xmin)
            ymins.append(ymin)
            xmaxs.append(xmax)
            ymaxs.append(ymax)
        return min(xmins), min(ymins), max(xmaxs), max(ymaxs)
    else:
        xyz = tuple(zip(*list(_explode(geometry['coordinates']))))
        return min(xyz[0]), min(xyz[1]), max(xyz[0]), max(xyz[1])


# Mapping of OGR integer geometry types to GeoJSON type names.
GEOMETRY_TYPES = {
    0: 'Unknown',
    1: 'Point',
    2: 'LineString',
    3: 'Polygon',
    4: 'MultiPoint',
    5: 'MultiLineString',
    6: 'MultiPolygon',
    7: 'GeometryCollection',
    100: 'None',
    101: 'LinearRing',
    0x80000001: '3D Point',
    0x80000002: '3D LineString',
    0x80000003: '3D Polygon',
    0x80000004: '3D MultiPoint',
    0x80000005: '3D MultiLineString',
    0x80000006: '3D MultiPolygon',
    0x80000007: '3D GeometryCollection'
}

# Mapping of GeoJSON type names to OGR integer geometry types
GEOJSON2OGR_GEOMETRY_TYPES = dict(
    (v, k) for k, v in GEOMETRY_TYPES.iteritems()
)


# Geometry related functions and classes follow.


cdef _deleteOgrGeom(void *cogr_geometry):
    """Delete an OGR geometry"""

    if cogr_geometry != NULL:
        _ogr.OGR_G_DestroyGeometry(cogr_geometry)
    cogr_geometry = NULL


cdef class GeomBuilder:
    """Builds a GeoJSON (Fiona-style) geometry from an OGR geometry."""

    cdef _buildCoords(self, void *geom):
        # Build a coordinate sequence
        cdef int i
        if geom == NULL:
            raise ValueError("Null geom")
        npoints = _ogr.OGR_G_GetPointCount(geom)
        coords = []
        for i in range(npoints):
            values = [_ogr.OGR_G_GetX(geom, i), _ogr.OGR_G_GetY(geom, i)]
            if self.ndims > 2:
                values.append(_ogr.OGR_G_GetZ(geom, i))
            coords.append(tuple(values))
        return coords

    cpdef _buildPoint(self):
        return {
            'type': 'Point',
            'coordinates': self._buildCoords(self.geom)[0]
        }

    cpdef _buildLineString(self):
        return {
            'type': 'LineString',
            'coordinates': self._buildCoords(self.geom)
        }

    cpdef _buildLinearRing(self):
        return {
            'type': 'LinearRing',
            'coordinates': self._buildCoords(self.geom)
        }

    cdef _buildParts(self, void *geom):
        cdef int j
        cdef void *part
        if geom == NULL:
            raise ValueError("Null geom")
        parts = []
        for j in range(_ogr.OGR_G_GetGeometryCount(geom)):
            part = _ogr.OGR_G_GetGeometryRef(geom, j)
            parts.append(GeomBuilder().build(part))
        return parts

    cpdef _buildPolygon(self):
        coordinates = [p['coordinates'] for p in self._buildParts(self.geom)]
        return {'type': 'Polygon', 'coordinates': coordinates}

    cpdef _buildMultiPolygon(self):
        coordinates = [p['coordinates'] for p in self._buildParts(self.geom)]
        return {'type': 'MultiPolygon', 'coordinates': coordinates}

    cdef build(self, void *geom):
        """Builds a GeoJSON object from an OGR geometry object."""

        if geom == NULL:
            raise ValueError("Null geom")

        cdef unsigned int etype = _ogr.OGR_G_GetGeometryType(geom)
        self.code = etype
        self.geomtypename = GEOMETRY_TYPES[self.code & (~0x80000000)]
        self.ndims = _ogr.OGR_G_GetCoordinateDimension(geom)
        self.geom = geom
        return getattr(self, '_build' + self.geomtypename)()


cdef class OGRGeomBuilder:
    """
    Builds an OGR geometry from GeoJSON geometry.
    From Fiona: https://github.com/Toblerity/Fiona/blob/master/src/fiona/ogrext.pyx
    """

    cdef void * _createOgrGeometry(self, int geom_type) except NULL:
        cdef void *cogr_geometry = _ogr.OGR_G_CreateGeometry(geom_type)
        if cogr_geometry is NULL:
            raise Exception(
                "Could not create OGR Geometry of type: %i" % geom_type
            )
        return cogr_geometry

    cdef _addPointToGeometry(self, void *cogr_geometry, object coordinate):
        if len(coordinate) == 2:
            x, y = coordinate
            _ogr.OGR_G_AddPoint_2D(cogr_geometry, x, y)
        else:
            x, y, z = coordinate[:3]
            _ogr.OGR_G_AddPoint(cogr_geometry, x, y, z)

    cdef void * _buildPoint(self, object coordinates) except NULL:
        cdef void *cogr_geometry = self._createOgrGeometry(
            GEOJSON2OGR_GEOMETRY_TYPES['Point']
        )
        self._addPointToGeometry(cogr_geometry, coordinates)
        return cogr_geometry

    cdef void * _buildLineString(self, object coordinates) except NULL:
        cdef void *cogr_geometry = self._createOgrGeometry(
            GEOJSON2OGR_GEOMETRY_TYPES['LineString']
        )
        for coordinate in coordinates:
            self._addPointToGeometry(cogr_geometry, coordinate)
        return cogr_geometry

    cdef void * _buildLinearRing(self, object coordinates) except NULL:
        cdef void *cogr_geometry = self._createOgrGeometry(
            GEOJSON2OGR_GEOMETRY_TYPES['LinearRing']
        )
        for coordinate in coordinates:
            self._addPointToGeometry(cogr_geometry, coordinate)
        _ogr.OGR_G_CloseRings(cogr_geometry)
        return cogr_geometry

    cdef void * _buildPolygon(self, object coordinates) except NULL:
        cdef void *cogr_ring
        cdef void *cogr_geometry = self._createOgrGeometry(
            GEOJSON2OGR_GEOMETRY_TYPES['Polygon']
        )
        for ring in coordinates:
            cogr_ring = self._buildLinearRing(ring)
            _ogr.OGR_G_AddGeometryDirectly(cogr_geometry, cogr_ring)
        return cogr_geometry

    cdef void * _buildMultiPoint(self, object coordinates) except NULL:
        cdef void *cogr_part
        cdef void *cogr_geometry = self._createOgrGeometry(
            GEOJSON2OGR_GEOMETRY_TYPES['MultiPoint']
        )
        for coordinate in coordinates:
            cogr_part = self._buildPoint(coordinate)
            _ogr.OGR_G_AddGeometryDirectly(cogr_geometry, cogr_part)
        return cogr_geometry

    cdef void * _buildMultiLineString(self, object coordinates) except NULL:
        cdef void *cogr_part
        cdef void *cogr_geometry = self._createOgrGeometry(
            GEOJSON2OGR_GEOMETRY_TYPES['MultiLineString']
        )
        for line in coordinates:
            cogr_part = self._buildLineString(line)
            _ogr.OGR_G_AddGeometryDirectly(cogr_geometry, cogr_part)
        return cogr_geometry

    cdef void * _buildMultiPolygon(self, object coordinates) except NULL:
        cdef void *cogr_part
        cdef void *cogr_geometry = self._createOgrGeometry(
            GEOJSON2OGR_GEOMETRY_TYPES['MultiPolygon']
        )
        for part in coordinates:
            cogr_part = self._buildPolygon(part)
            _ogr.OGR_G_AddGeometryDirectly(cogr_geometry, cogr_part)
        return cogr_geometry

    cdef void * _buildGeometryCollection(self, object coordinates) except NULL:
        cdef void *cogr_part
        cdef void *cogr_geometry = self._createOgrGeometry(
            GEOJSON2OGR_GEOMETRY_TYPES['GeometryCollection']
        )
        for part in coordinates:
            cogr_part = OGRGeomBuilder().build(part)
            _ogr.OGR_G_AddGeometryDirectly(cogr_geometry, cogr_part)
        return cogr_geometry

    cdef void * build(self, object geometry) except NULL:
        """Builds an OGR geometry from GeoJSON geometry."""

        cdef object typename = geometry['type']
        cdef object coordinates = geometry.get('coordinates')
        if not typename or not coordinates:
            raise ValueError("Input is not a valid geometry object")
        if typename == 'Point':
            return self._buildPoint(coordinates)
        elif typename == 'LineString':
            return self._buildLineString(coordinates)
        elif typename == 'LinearRing':
            return self._buildLinearRing(coordinates)
        elif typename == 'Polygon':
            return self._buildPolygon(coordinates)
        elif typename == 'MultiPoint':
            return self._buildMultiPoint(coordinates)
        elif typename == 'MultiLineString':
            return self._buildMultiLineString(coordinates)
        elif typename == 'MultiPolygon':
            return self._buildMultiPolygon(coordinates)
        elif typename == 'GeometryCollection':
            coordinates = geometry.get('geometries')
            return self._buildGeometryCollection(coordinates)
        else:
            raise ValueError("Unsupported geometry type %s" % typename)


# Feature extension classes and functions follow.

cdef _deleteOgrFeature(void *cogr_feature):
    """Delete an OGR feature"""
    if cogr_feature != NULL:
        _ogr.OGR_F_Destroy(cogr_feature)
    cogr_feature = NULL


cdef class ShapeIterator:
    """Provides an iterator over shapes in an OGR feature layer."""

    # Reference to its Collection
    cdef void *hfs
    cdef void *hlayer

    cdef int fieldtp  # OGR Field Type: 0=int, 2=double

    def __iter__(self):
        _ogr.OGR_L_ResetReading(self.hlayer)
        return self

    def __next__(self):
        cdef long fid
        cdef void *ftr
        cdef void *geom
        ftr = _ogr.OGR_L_GetNextFeature(self.hlayer)
        if ftr == NULL:
            raise StopIteration
        if self.fieldtp == 0:
            image_value = _ogr.OGR_F_GetFieldAsInteger(ftr, 0)
        else:
            image_value = _ogr.OGR_F_GetFieldAsDouble(ftr, 0)
        geom = _ogr.OGR_F_GetGeometryRef(ftr)
        if geom != NULL:
            shape = GeomBuilder().build(geom)
        else:
            shape = None
        _deleteOgrFeature(ftr)
        return shape, image_value
