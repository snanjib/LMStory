"""Configuration and matching checks for the public-surface guard."""
import os
import unittest
from unittest.mock import patch

import check_residual_traces as guard


class ResidualGuardTest(unittest.TestCase):
    def test_configuration_is_required_and_validated(self):
        for value in (None, '', '[]', '[1]', '[" "]', 'invalid'):
            with self.subTest(value=value), patch.dict(os.environ, {}, clear=True):
                if value is not None:
                    os.environ['LMSTORY_GUARD_IDENTITY_TERMS'] = value
                with self.assertRaises(ValueError):
                    guard.configured_terms('LMSTORY_GUARD_IDENTITY_TERMS')

    def test_literal_terms_and_private_addresses_match(self):
        with patch.dict(os.environ, {
            'LMSTORY_GUARD_IDENTITY_TERMS': '["example.identity"]',
            'LMSTORY_GUARD_NETWORK_TERMS': '["example-network"]',
        }):
            families = dict(guard.families())
            self.assertIsNotNone(families['identity'].search('EXAMPLE.IDENTITY'))
            self.assertIsNone(families['identity'].search('exampleXidentity'))
            self.assertIsNotNone(families['network'].search('EXAMPLE-NETWORK'))
            self.assertIsNotNone(families['network'].search('.'.join(('192', '168', '1', '42'))))


if __name__ == '__main__':
    unittest.main()
