# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2020 Nautech Systems Pty Ltd. All rights reserved.
#  https://nautechsystems.io
#
#  Licensed under the GNU General Public License Version 3.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at https://www.gnu.org/licenses/gpl-3.0.en.html
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# -------------------------------------------------------------------------------------------------

from nautilus_trader.indicators.base.indicator cimport Indicator


cdef class HilbertTransform(Indicator):
    cdef double _i_mult
    cdef double _q_mult
    cdef object _inputs
    cdef object _detrended_prices
    cdef object _in_phase
    cdef object _quadrature

    cdef readonly int period
    cdef readonly double value_in_phase
    cdef readonly double value_quad

    cpdef void update(self, double price)
    cpdef void reset(self)