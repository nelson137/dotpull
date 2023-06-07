# -*- coding: utf-8 -*-
# Copyright (c) 2021, Abhijeet Kasurde <akasurde@redhat.com>
# Copyright (c) 2018, Ansible Project
# GNU General Public License v3.0+ (see LICENSES/GPL-3.0-or-later.txt or https://www.gnu.org/licenses/gpl-3.0.txt)
# SPDX-License-Identifier: GPL-3.0-or-later

from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
name: idempotent_secret
author: Nelson Earle
short_description: TODO
description:
  - TODO
options:
  _terms:
    description: name of the secret
    required: true
  length:
    description: The length of the string.
    default: 16
    type: int
  upper:
    description:
    - Include uppercase letters in the string.
    default: true
    type: bool
  lower:
    description:
    - Include lowercase letters in the string.
    default: true
    type: bool
  numbers:
    description:
    - Include numbers in the string.
    default: true
    type: bool
  special:
    description:
    - Include special characters in the string.
    - Special characters are taken from Python standard library C(string).
      See L(the documentation of string.punctuation,https://docs.python.org/3/library/string.html#string.punctuation)
      for which characters will be used.
    - The choice of special characters can be changed to setting I(override_special).
    default: false
    type: bool
  min_numeric:
    description:
    - Minimum number of numeric characters in the string.
    - If set, overrides I(numbers=false).
    default: 0
    type: int
  min_upper:
    description:
    - Minimum number of uppercase alphabets in the string.
    - If set, overrides I(upper=false).
    default: 0
    type: int
  min_lower:
    description:
    - Minimum number of lowercase alphabets in the string.
    - If set, overrides I(lower=false).
    default: 0
    type: int
  min_special:
    description:
    - Minimum number of special character in the string.
    default: 0
    type: int
  override_special:
    description:
    - Overide a list of special characters to use in the string.
    - If set I(min_special) should be set to a non-default value.
    type: str
  override_all:
    description:
    - Override all values of I(numbers), I(upper), I(lower), and I(special) with
      the given list of characters.
    type: str
  base64:
    description:
    - Returns base64 encoded string.
    type: bool
    default: false
"""

import os
import shelve

from ansible import constants as C
from ansible.errors import AnsibleOptionsError
from ansible.plugins.loader import lookup_loader
from ansible.plugins.lookup import LookupBase
from ansible.utils.display import Display

display = Display()

CACHE_PATH = os.path.join(C.DEFAULT_LOCAL_TMP, 'idempotent_secret_cache')

class LookupModule(LookupBase):

    def run(self, terms, variables=None, **kwargs):

        if len(terms) == 0:
            return []
        name = terms[0]

        self.set_options(var_options=variables, direct=kwargs)
        options = self.get_options()

        with shelve.open(CACHE_PATH) as cache:
            ret = []

            try:
                ret = cache[name]
                display.verbose(f'idempotent_secret: cache hit for {name}')

            except KeyError:
                lookup = lookup_loader.get('random_string',
                    loader=self._loader, templar=self._templar)
                if lookup is None:
                    raise AnsibleError('lookup plugin (random_string) not found')

                ret = lookup.run([], variables=variables, **options)
                cache[name] = ret
                display.verbose(f'idempotent_secret: cache miss for {name}')

            return ret
