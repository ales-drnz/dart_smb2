// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

void main() {
  group('Smb2ShareInfo', () {
    test('baseType masks the low two bits', () {
      const s = Smb2ShareInfo(
        name: 'C\$',
        type: Smb2ShareType.diskTree | Smb2ShareType.hidden,
      );
      expect(s.baseType, Smb2ShareType.diskTree);
    });

    test('isDisk is true for a disk tree', () {
      expect(
        const Smb2ShareInfo(
          name: 'Public',
          type: Smb2ShareType.diskTree,
        ).isDisk,
        isTrue,
      );
      expect(
        const Smb2ShareInfo(name: 'IPC\$', type: Smb2ShareType.ipc).isDisk,
        isFalse,
      );
    });

    test('isHidden detects the hidden flag', () {
      expect(
        const Smb2ShareInfo(
          name: 'admin',
          type: Smb2ShareType.diskTree | Smb2ShareType.hidden,
        ).isHidden,
        isTrue,
      );
    });

    test('isHidden detects a trailing-\$ name even without the flag', () {
      expect(
        const Smb2ShareInfo(
          name: 'ADMIN\$',
          type: Smb2ShareType.diskTree,
        ).isHidden,
        isTrue,
      );
    });

    test('isHidden is false for a plain share', () {
      expect(
        const Smb2ShareInfo(
          name: 'Music',
          type: Smb2ShareType.diskTree,
        ).isHidden,
        isFalse,
      );
    });

    test('toString includes name and type', () {
      final s = const Smb2ShareInfo(name: 'Public', type: 0).toString();
      expect(s, contains('Public'));
    });
  });

  group('Smb2Stat', () {
    final dir = Smb2Stat(
      type: Smb2FileType.directory,
      size: 0,
      modified: DateTime.utc(2024),
      created: DateTime.utc(2024),
      accessed: DateTime.utc(2024),
      changed: DateTime.utc(2024),
    );
    final file = Smb2Stat(
      type: Smb2FileType.file,
      size: 42,
      modified: DateTime.utc(2024),
      created: DateTime.utc(2024),
      accessed: DateTime.utc(2024),
      changed: DateTime.utc(2024),
    );

    test('isDirectory / isFile reflect the type', () {
      expect(dir.isDirectory, isTrue);
      expect(dir.isFile, isFalse);
      expect(file.isFile, isTrue);
      expect(file.isDirectory, isFalse);
    });

    test('toString includes type and size', () {
      expect(file.toString(), contains('42'));
    });
  });

  group('Smb2DirEntry', () {
    final entry = Smb2DirEntry(
      name: 'song.flac',
      stat: Smb2Stat(
        type: Smb2FileType.file,
        size: 1234,
        modified: DateTime.utc(2024),
        created: DateTime.utc(2024),
        accessed: DateTime.utc(2024),
        changed: DateTime.utc(2024),
      ),
    );

    test('forwards isFile / isDirectory / size from stat', () {
      expect(entry.isFile, isTrue);
      expect(entry.isDirectory, isFalse);
      expect(entry.size, 1234);
    });

    test('toString includes the name', () {
      expect(entry.toString(), contains('song.flac'));
    });
  });

  group('Smb2StatVfs', () {
    const vfs = Smb2StatVfs(
      blockSize: 4096,
      fragmentSize: 4096,
      totalBlocks: 100,
      freeBlocks: 40,
      availableBlocks: 30,
      maxNameLength: 255,
    );

    test('derived byte sizes multiply blocks by fragment size', () {
      expect(vfs.totalSize, 100 * 4096);
      expect(vfs.freeSize, 40 * 4096);
      expect(vfs.availableSize, 30 * 4096);
    });

    test('toString includes totals', () {
      expect(vfs.toString(), contains('${100 * 4096}'));
    });
  });

  group('Smb2Stat attributes', () {
    Smb2Stat withAttributes(int attributes) => Smb2Stat(
      type: Smb2FileType.file,
      size: 0,
      modified: DateTime.utc(2024),
      created: DateTime.utc(2024),
      accessed: DateTime.utc(2024),
      changed: DateTime.utc(2024),
      attributes: attributes,
    );

    test('isHidden reads FILE_ATTRIBUTE_HIDDEN', () {
      expect(withAttributes(0x2).isHidden, isTrue);
      expect(withAttributes(0x20).isHidden, isFalse);
    });

    test('attributes take part in equality', () {
      expect(withAttributes(0x2), isNot(equals(withAttributes(0))));
    });
  });

  group('Smb2ShareInfo remark', () {
    test('defaults to empty and takes part in equality', () {
      const a = Smb2ShareInfo(name: 'm', type: 0);
      expect(a.remark, '');
      expect(
        a,
        isNot(equals(const Smb2ShareInfo(name: 'm', type: 0, remark: 'x'))),
      );
    });
  });

  group('Smb2Version', () {
    test('carries the wire value libsmb2 expects', () {
      expect(Smb2Version.any.value, 0);
      expect(Smb2Version.v311.value, 0x0311);
    });
  });

  group('value equality', () {
    Smb2Stat stat({int size = 1}) => Smb2Stat(
      type: Smb2FileType.file,
      size: size,
      modified: DateTime.utc(2024),
      created: DateTime.utc(2024),
      accessed: DateTime.utc(2024),
      changed: DateTime.utc(2024),
    );

    test('Smb2ShareInfo equals by value and shares a hashCode', () {
      const a = Smb2ShareInfo(name: 'Public', type: 0);
      const b = Smb2ShareInfo(name: 'Public', type: 0);
      const c = Smb2ShareInfo(name: 'Public', type: 1);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('Smb2Stat equals by value', () {
      expect(stat(size: 5), equals(stat(size: 5)));
      expect(stat(size: 5), isNot(equals(stat(size: 6))));
      expect(stat(size: 5).hashCode, stat(size: 5).hashCode);
    });

    test('Smb2DirEntry equals by value (incl. nested stat)', () {
      final a = Smb2DirEntry(name: 'f', stat: stat(size: 9));
      final b = Smb2DirEntry(name: 'f', stat: stat(size: 9));
      final c = Smb2DirEntry(name: 'f', stat: stat(size: 8));
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('Smb2StatVfs equals by value', () {
      const a = Smb2StatVfs(
        blockSize: 4096,
        fragmentSize: 4096,
        totalBlocks: 100,
        freeBlocks: 40,
        availableBlocks: 30,
        maxNameLength: 255,
      );
      const b = Smb2StatVfs(
        blockSize: 4096,
        fragmentSize: 4096,
        totalBlocks: 100,
        freeBlocks: 40,
        availableBlocks: 30,
        maxNameLength: 255,
      );
      const c = Smb2StatVfs(
        blockSize: 4096,
        fragmentSize: 4096,
        totalBlocks: 100,
        freeBlocks: 41,
        availableBlocks: 30,
        maxNameLength: 255,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('value objects work as Set members', () {
      final set = {stat(), stat(), stat(size: 2)};
      expect(set.length, 2);
    });
  });
}
