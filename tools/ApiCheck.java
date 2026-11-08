import java.io.*;
import java.util.*;
import java.util.zip.*;

/**
 * Class-file level API checker for the emulator's Java layer.
 *
 *   java tools/ApiCheck.java spec  <api.jar>...  -- <runtime.jar>...
 *       every public/protected class member of the reference API (for example
 *       the real midp_2.0.jar / cldc_1.0.jar stubs) that the runtime lacks
 *
 *   java tools/ApiCheck.java refs  <game.jar>    -- <runtime.jar>...
 *       every class, field and method a game refers to that neither the game
 *       nor the runtime defines (each one is a NoClassDefFoundError or
 *       NoSuchMethodError waiting to happen on the device)
 *
 *   java tools/ApiCheck.java usage <game.jar>    -- <prefix>...
 *       which platform methods a game calls, one per line
 *
 * Exit status: 0 = nothing missing, 1 = something missing.
 */
public class ApiCheck {

    static final class Member {
        final String name, desc; final int flags;
        Member(String n, String d, int f) { name = n; desc = d; flags = f; }
    }

    static final class Ref {
        final int kind; final String owner, name, desc;
        Ref(int k, String o, String n, String d) { kind = k; owner = o; name = n; desc = d; }
    }

    static final class Cls {
        String name, superName; int flags;
        final List<String> interfaces = new ArrayList<>();
        final List<Member> fields = new ArrayList<>(), methods = new ArrayList<>();
        final List<Ref> refs = new ArrayList<>();
        final Set<String> classRefs = new TreeSet<>();
    }

    static final int ACC_PUBLIC = 1, ACC_PROTECTED = 4, ACC_SYNTHETIC = 0x1000;

    static Cls parse(byte[] b) throws IOException {
        DataInputStream in = new DataInputStream(new ByteArrayInputStream(b));
        if (in.readInt() != 0xCAFEBABE) throw new IOException("not a class file");
        in.readUnsignedShort(); in.readUnsignedShort();
        int n = in.readUnsignedShort();
        Object[] cp = new Object[n];
        int[][] links = new int[n][];
        int[] tags = new int[n];
        for (int i = 1; i < n; i++) {
            int t = in.readUnsignedByte();
            tags[i] = t;
            switch (t) {
                case 1: cp[i] = in.readUTF(); break;
                case 3: case 4: in.readInt(); break;
                case 5: case 6: in.readLong(); i++; break;
                case 7: case 8: case 16: case 19: case 20: links[i] = new int[]{in.readUnsignedShort()}; break;
                case 9: case 10: case 11: case 12: case 17: case 18:
                    links[i] = new int[]{in.readUnsignedShort(), in.readUnsignedShort()}; break;
                case 15: links[i] = new int[]{in.readUnsignedByte(), in.readUnsignedShort()}; break;
                default: throw new IOException("bad constant tag " + t);
            }
        }
        Cls c = new Cls();
        c.flags = in.readUnsignedShort();
        c.name = (String) cp[links[in.readUnsignedShort()][0]];
        int sup = in.readUnsignedShort();
        c.superName = sup == 0 ? null : (String) cp[links[sup][0]];
        int ifaces = in.readUnsignedShort();
        for (int i = 0; i < ifaces; i++) c.interfaces.add((String) cp[links[in.readUnsignedShort()][0]]);
        for (int pass = 0; pass < 2; pass++) {
            int count = in.readUnsignedShort();
            for (int i = 0; i < count; i++) {
                int f = in.readUnsignedShort();
                String name = (String) cp[in.readUnsignedShort()], desc = (String) cp[in.readUnsignedShort()];
                (pass == 0 ? c.fields : c.methods).add(new Member(name, desc, f));
                int attrs = in.readUnsignedShort();
                for (int a = 0; a < attrs; a++) { in.readUnsignedShort(); in.skipBytes(in.readInt()); }
            }
        }
        for (int i = 1; i < n; i++) {
            if (tags[i] == 7) {
                String s = (String) cp[links[i][0]];
                if (s != null) c.classRefs.add(s);
            } else if (tags[i] == 9 || tags[i] == 10 || tags[i] == 11) {
                String owner = (String) cp[links[links[i][0]][0]];
                int[] nt = links[links[i][1]];
                c.refs.add(new Ref(tags[i], owner, (String) cp[nt[0]], (String) cp[nt[1]]));
            }
        }
        return c;
    }

    static Map<String, Cls> load(List<String> jars) throws IOException {
        Map<String, Cls> all = new TreeMap<>();
        for (String jar : jars) {
            try (ZipFile z = new ZipFile(jar)) {
                for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements(); ) {
                    ZipEntry entry = e.nextElement();
                    if (!entry.getName().endsWith(".class")) continue;
                    try (InputStream is = z.getInputStream(entry)) {
                        Cls c = parse(is.readAllBytes());
                        all.putIfAbsent(c.name, c);
                    } catch (IOException ex) {
                        System.err.println("skip " + entry.getName() + ": " + ex.getMessage());
                    }
                }
            }
        }
        return all;
    }

    /** Looks a member up the same way the JVM does: class, superclasses, interfaces. */
    static boolean has(Map<String, Cls> world, String owner, String name, String desc, boolean method, Set<String> seen) {
        if (owner == null || !seen.add(owner)) return false;
        Cls c = world.get(owner);
        if (c == null) return false;
        for (Member m : method ? c.methods : c.fields)
            if (m.name.equals(name) && m.desc.equals(desc)) return true;
        if (has(world, c.superName, name, desc, method, seen)) return true;
        for (String i : c.interfaces) if (has(world, i, name, desc, method, seen)) return true;
        return false;
    }

    static boolean isVisible(int flags) { return (flags & (ACC_PUBLIC | ACC_PROTECTED)) != 0; }

    static String pretty(String desc) {
        StringBuilder out = new StringBuilder("(");
        int i = 1, n = desc.indexOf(')');
        boolean first = true;
        while (i < n) {
            int start = i;
            while (desc.charAt(i) == '[') i++;
            if (desc.charAt(i) == 'L') i = desc.indexOf(';', i);
            i++;
            if (!first) out.append(", ");
            first = false;
            out.append(type(desc.substring(start, i)));
        }
        return out.append(")").toString();
    }

    static String type(String d) {
        int dims = 0;
        while (d.charAt(dims) == '[') dims++;
        String base = d.substring(dims);
        String r;
        switch (base.charAt(0)) {
            case 'B': r = "byte"; break; case 'C': r = "char"; break; case 'D': r = "double"; break;
            case 'F': r = "float"; break; case 'I': r = "int"; break; case 'J': r = "long"; break;
            case 'S': r = "short"; break; case 'Z': r = "boolean"; break; case 'V': r = "void"; break;
            default:
                r = base.substring(1, base.length() - 1);
                r = r.substring(r.lastIndexOf('/') + 1);
        }
        return r + "[]".repeat(dims);
    }

    static int spec(List<String> api, List<String> impl) throws IOException {
        Map<String, Cls> ref = load(api), world = load(impl);
        int missingClasses = 0, missingMembers = 0, total = 0;
        for (Cls c : ref.values()) {
            if ((c.flags & ACC_PUBLIC) == 0) continue;
            total++;
            if (!world.containsKey(c.name)) {
                System.out.println("MISSING CLASS   " + c.name.replace('/', '.'));
                missingClasses++;
                continue;
            }
            for (int pass = 0; pass < 2; pass++) {
                boolean method = pass == 1;
                for (Member m : method ? c.methods : c.fields) {
                    if (!isVisible(m.flags) || (m.flags & ACC_SYNTHETIC) != 0) continue;
                    if (m.name.equals("<clinit>")) continue;
                    total++;
                    if (has(world, c.name, m.name, m.desc, method, new HashSet<>())) continue;
                    missingMembers++;
                    String shown = method ? m.name + pretty(m.desc) : m.name;
                    System.out.println("MISSING " + (method ? "METHOD  " : "FIELD   ") + c.name.replace('/', '.') + "." + shown);
                }
            }
        }
        System.out.println();
        System.out.println("API items checked: " + total + ", missing classes: " + missingClasses + ", missing members: " + missingMembers);
        return missingClasses + missingMembers == 0 ? 0 : 1;
    }

    static int refs(String game, List<String> impl) throws IOException {
        Map<String, Cls> own = load(List.of(game)), world = load(impl);
        Map<String, Cls> all = new TreeMap<>(world);
        all.putAll(own);
        Set<String> missing = new TreeSet<>();
        for (Cls c : own.values()) {
            for (String r : c.classRefs) {
                if (r.startsWith("[")) continue;
                if (!all.containsKey(r)) missing.add("CLASS  " + r.replace('/', '.'));
            }
            for (Ref r : c.refs) {
                if (r.owner.startsWith("[")) continue;
                if (!all.containsKey(r.owner)) continue;
                boolean method = r.kind != 9;
                if (has(all, r.owner, r.name, r.desc, method, new HashSet<>())) continue;
                missing.add((method ? "METHOD " : "FIELD  ") + r.owner.replace('/', '.') + "." + r.name + (method ? pretty(r.desc) : ""));
            }
        }
        missing.forEach(System.out::println);
        System.out.println();
        System.out.println(own.size() + " game classes, unresolved references: " + missing.size());
        return missing.isEmpty() ? 0 : 1;
    }

    static int usage(String game, List<String> prefixes) throws IOException {
        Map<String, Cls> own = load(List.of(game));
        Map<String, Integer> counts = new TreeMap<>();
        for (Cls c : own.values())
            for (Ref r : c.refs) {
                if (own.containsKey(r.owner)) continue;
                boolean match = prefixes.isEmpty();
                for (String p : prefixes) if (r.owner.startsWith(p.replace('.', '/'))) match = true;
                if (!match) continue;
                String key = r.owner.replace('/', '.') + "." + r.name + (r.kind == 9 ? "" : pretty(r.desc));
                counts.merge(key, 1, Integer::sum);
            }
        counts.forEach((k, v) -> System.out.println(v + "\t" + k));
        return 0;
    }

    public static void main(String[] a) throws Exception {
        int sep = Arrays.asList(a).indexOf("--");
        if (a.length < 3 || sep < 2) {
            System.err.println("usage: ApiCheck spec|refs|usage <jars...> -- <jars or prefixes...>");
            System.exit(2);
        }
        List<String> left = Arrays.asList(a).subList(1, sep), right = Arrays.asList(a).subList(sep + 1, a.length);
        int rc;
        switch (a[0]) {
            case "spec": rc = spec(left, right); break;
            case "refs": rc = refs(left.get(0), right); break;
            case "usage": rc = usage(left.get(0), right); break;
            default: throw new IllegalArgumentException(a[0]);
        }
        System.exit(rc);
    }
}
