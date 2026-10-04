"""Keep one verified, non-indexable ZIP for the current Alfred release."""
from pathlib import Path
import hashlib, os, tempfile, zipfile


def bundle_hashes(bundle):
    return {str(p.relative_to(bundle)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(Path(bundle).rglob('*')) if p.is_file()}


def archive_hashes(archive, app_name='Alfred.app'):
    prefix = app_name + '/'
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None, 'Archive CRC failure'
        files = {i.filename[len(prefix):]: hashlib.sha256(z.read(i)).hexdigest()
                 for i in z.infolist() if i.filename.startswith(prefix) and not i.is_dir()}
    assert files, 'Empty release archive'
    return files


def archive_bundle(bundle, target):
    bundle, target = Path(bundle), Path(target)
    assert not bundle.is_symlink() and bundle.name == 'Alfred.app'
    assert not any(p.is_symlink() for p in bundle.rglob('*')), 'Symlink archival needs explicit handling'
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.alfred-archive-', suffix='.zip', dir=target.parent)
    os.close(fd)
    temporary = Path(name)
    try:
        with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as z:
            for p in sorted(bundle.rglob('*')):
                z.write(p, str(Path(bundle.name) / p.relative_to(bundle)))
        assert archive_hashes(temporary, bundle.name) == bundle_hashes(bundle), 'Archive differs from installed app'
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target
