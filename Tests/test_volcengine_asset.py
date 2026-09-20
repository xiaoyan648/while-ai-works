"""Local request-construction checks; no generation service is contacted."""
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / 'scripts/art/generate_volcengine_asset.py'
spec = importlib.util.spec_from_file_location('asset_generator', source)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)

class GenerationChecks(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.rootPatch = patch.object(generator, 'ROOT', self.root)
        self.rootPatch.start()
        fish = self.root / 'Sources/WhileAIWorks/Resources/FishAssets/carp.png'
        fish.parent.mkdir(parents=True); fish.write_bytes(b'fish-reference')
        props = self.root / 'art/aquascape-v3'
        props.mkdir(parents=True)
        (props / 'driftwood').mkdir()
        (props / 'driftwood/reference.png').write_bytes(b'wood-reference')
        (props / 'tasks.json').write_text(json.dumps({'assets': [{
            'id': 'driftwood', 'reference': 'art/aquascape-v3/driftwood/reference.png',
            'prompt': 'An independent weathered driftwood prop.'}]}))

    def tearDown(self):
        self.rootPatch.stop(); self.folder.cleanup()

    def test_existing_fish_call_keeps_its_directory_and_prompt(self):
        with patch.object(generator.urllib.request, 'urlopen', return_value=io.BytesIO(b'{"id":"task-fish"}')) as api:
            result = generator.run('test-only-key', {'action': 'submit', 'id': 'carp'})
        request = api.call_args.args[0]
        body = json.loads(request.data)
        self.assertIn('3D carp fish', body['content'][0]['text'])
        self.assertEqual(result['task_id'], 'task-fish')
        self.assertTrue((self.root/'art/volcengine-fish-v1/carp/generation-manifest.json').exists())

    def test_prop_call_uses_prop_reference_prompt_and_separate_manifest(self):
        with patch.object(generator.urllib.request, 'urlopen', return_value=io.BytesIO(b'{"id":"task-wood"}')) as api:
            generator.run('test-only-key', {'action': 'submit', 'id': 'driftwood', 'kind': 'aquascape'})
        body = json.loads(api.call_args.args[0].data)
        self.assertEqual(body['content'][0]['text'], 'An independent weathered driftwood prop.')
        self.assertTrue(body['content'][1]['image_url']['url'].endswith('d29vZC1yZWZlcmVuY2U='))
        raw = (self.root/'art/aquascape-v3/driftwood/generation-manifest.json').read_text()
        self.assertNotIn('test-only-key', raw)
        self.assertEqual(json.loads(raw)['asset_kind'], 'aquascape')

    def test_uncertain_submission_cannot_be_automatically_submitted_again(self):
        command = {'action': 'submit', 'id': 'driftwood', 'kind': 'aquascape'}
        with patch.object(generator.urllib.request, 'urlopen', side_effect=TimeoutError('test timeout')) as api:
            result = generator.run('test-only-key', command)
            self.assertEqual(result['status'], 'submission_uncertain')
            with self.assertRaisesRegex(RuntimeError, 'Manifest exists'):
                generator.run('test-only-key', command)
            self.assertEqual(api.call_count, 1)

    def test_unknown_prop_cannot_submit(self):
        with patch.object(generator.urllib.request, 'urlopen') as api:
            with self.assertRaisesRegex(AssertionError, 'Unknown aquascape prop'):
                generator.run('test-only-key', {'action': 'submit', 'id': 'carp', 'kind': 'aquascape'})
            api.assert_not_called()

if __name__ == '__main__':
    unittest.main()
